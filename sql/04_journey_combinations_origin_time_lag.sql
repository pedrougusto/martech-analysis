DECLARE dt_ini DATE DEFAULT '2026-01-01';
DECLARE dt_fim DATE DEFAULT '2026-06-30';
DECLARE janela_horas INT64 DEFAULT 48;

-- 1. IDENTIFICAÇÃO DO PACIENTE (MDM)
WITH cpf_match AS (
  SELECT CAST(id AS STRING) AS id_paciente, REGEXP_EXTRACT(main_key, r"[0-9]{11}") AS cpf
  FROM `app-prd.ds_trusted_dataform_cadastro_mdm.tb_trusted_tel_cadastro-mdm-people`
  WHERE REGEXP_EXTRACT(main_key, r"[0-9]{11}") IS NOT NULL
),

-- 2. TOUCHPOINTS DIGITAIS E SUBCANAIS
digital_tp AS (
  SELECT
    m.cpf,
    a.data AS dt_touch,
    TIMESTAMP_MICROS(a.first_event_timestamp) AS ts_touch,
    CASE
      WHEN (LOWER(a.medium) IN ('cpc','cpm','paid') OR LOWER(a.source) IN ('cpc','cpm','paid') OR LOWER(a.source) LIKE '%cpc%' OR LOWER(a.medium) LIKE '%cpc%') AND LOWER(a.source) NOT IN ('facebook','instagram','tiktok','twitter') THEN 'Paid Search'
      WHEN (LOWER(a.source) LIKE '%direct%' AND LOWER(a.medium) LIKE '%none%') OR LOWER(a.source) = '(not set)' OR LOWER(a.medium) = '(not set)' THEN 'Direto'
      WHEN ((REGEXP_CONTAINS(LOWER(COALESCE(a.source, '')), r'crm|insider|e-?mail') OR REGEXP_CONTAINS(LOWER(COALESCE(a.medium, '')), r'crm|insider|e-?mail')) AND REGEXP_CONTAINS(LOWER(COALESCE(a.campaign, '')), r'crcr|crmcore')) OR (LOWER(COALESCE(a.medium, '')) LIKE '%web_push%' AND LOWER(COALESCE(a.campaign, '')) LIKE '%crmcore%') THEN 'CRM Marketing'
      ELSE NULL
    END AS subcanal
  FROM `analytics-project.ds_dimfacto_dataform_app_pac_attribution.tb_dim_ga_app_pac_attribution_last_click` a
  LEFT JOIN cpf_match m ON CAST(a.user_id AS STRING) = m.id_paciente
  WHERE a.data BETWEEN dt_ini AND dt_fim AND m.cpf IS NOT NULL 
  GROUP BY ALL
  HAVING subcanal IN ('Paid Search', 'CRM Marketing', 'Direto')
),

-- 3. SEQUENCIAMENTO DOS PASSOS (LEAD)
sequenciado AS (
  SELECT *,
    LEAD(subcanal, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS passo_2,
    LEAD(ts_touch, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS ts_passo_2,
    LEAD(subcanal, 2) OVER (PARTITION BY cpf ORDER BY ts_touch) AS passo_3,
    LEAD(ts_touch, 2) OVER (PARTITION BY cpf ORDER BY ts_touch) AS ts_passo_3
  FROM digital_tp
),

-- 4. CONSOLIDAÇÃO DA JORNADA E ESTIMATIVA DE CUSTO
jornadas_paciente AS (
  SELECT
    cpf,
    ts_touch AS inicio_jornada,
    TIMESTAMP_DIFF(ts_passo_2, ts_touch, HOUR) AS lag_horas_passo2,
    CASE 
      WHEN subcanal = 'Direto' AND passo_2 = 'Paid Search' AND passo_3 = 'CRM Marketing' AND TIMESTAMP_DIFF(ts_passo_3, ts_touch, HOUR) <= janela_horas THEN 'Direto > Paid Search > CRM Marketing'
      WHEN subcanal = 'Direto' AND passo_2 = 'Paid Search' AND TIMESTAMP_DIFF(ts_passo_2, ts_touch, HOUR) <= janela_horas THEN 'Direto > Paid Search'
      WHEN subcanal = 'Paid Search' AND passo_2 = 'Direto' AND TIMESTAMP_DIFF(ts_passo_2, ts_touch, HOUR) <= janela_horas THEN 'Paid Search > Direto'
      WHEN subcanal = 'Direto' AND passo_2 = 'CRM Marketing' AND TIMESTAMP_DIFF(ts_passo_2, ts_touch, HOUR) <= janela_horas THEN 'Direto > CRM Marketing'
      ELSE subcanal
    END AS tipo_jornada
  FROM sequenciado
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cpf, DATE(ts_touch) ORDER BY ts_touch ASC) = 1
),

-- 5. O MUNDO TRANSACIONAL (Apenas 1 por dia para não duplicar jornada)
transacional_resumo AS (
  SELECT 
    nu_cpf_paciente AS cpf,
    dt_criacao_agendamento,
    origem_operador_agendamento AS canal_final, 
    CASE WHEN UPPER(noshow_ficha) = 'SIM' AND UPPER(noshow_por_paciente) = 'SIM' AND UPPER(st_agendamento) = 'BOOKED' THEN 1 ELSE 0 END AS flag_no_show
  FROM `company-bi-prd.ds_datamart_agendamento.fct_datamart_agendamento`
  WHERE dt_criacao_agendamento >= dt_ini AND nu_cpf_paciente IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY nu_cpf_paciente, DATE(dt_criacao_agendamento) ORDER BY dt_criacao_agendamento ASC) = 1
)

-- 6. VISÃO EXECUTIVA FINAL
SELECT 
  CASE WHEN j.tipo_jornada = 'Direto' AND t.flag_no_show = 1 THEN 'Direto > No Show' ELSE j.tipo_jornada END AS visao_jornada,
  COALESCE(t.canal_final, 'UNIDADES') AS canal_de_conversao,
  
  -- CORREÇÃO: Trava de segurança para Jornadas Únicas
  CASE 
    WHEN j.tipo_jornada NOT LIKE '%>%' THEN 'Jornada Única'
    WHEN j.lag_horas_passo2 <= 1 THEN 'Até 1h'
    WHEN j.lag_horas_passo2 > 1 AND j.lag_horas_passo2 <= 6 THEN '1 a 6h'
    WHEN j.lag_horas_passo2 > 6 AND j.lag_horas_passo2 <= 24 THEN '6 a 24h'
    WHEN j.lag_horas_passo2 > 24 THEN '+24h'
    ELSE 'Jornada Única'
  END AS time_lag,
  
  COUNT(DISTINCT j.cpf) AS volume_jornadas,
  ROUND(SUM(CASE 
    WHEN j.tipo_jornada LIKE '%Paid Search%' THEN 0.77 
    WHEN j.tipo_jornada LIKE '%CRM Marketing%' THEN 0.16 
    ELSE 0 
  END), 2) AS investimento_estimado

  
FROM jornadas_paciente j
LEFT JOIN transacional_resumo t ON j.cpf = t.cpf AND t.dt_criacao_agendamento BETWEEN DATETIME(j.inicio_jornada) AND DATETIME_ADD(DATETIME(j.inicio_jornada), INTERVAL 5 DAY)
GROUP BY ALL
ORDER BY volume_jornadas DESC