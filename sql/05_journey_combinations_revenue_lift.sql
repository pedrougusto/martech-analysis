DECLARE dt_ini DATE DEFAULT '2026-01-01';
DECLARE dt_fim DATE DEFAULT '2026-06-30';
DECLARE janela_horas INT64 DEFAULT 48;

-- 1. IDENTIFICAÇÃO DO PACIENTE
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

-- 3. SEQUENCIAMENTO DOS PASSOS
sequenciado AS (
  SELECT *,
    LEAD(subcanal, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS passo_2,
    LEAD(ts_touch, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS ts_passo_2,
    LEAD(subcanal, 2) OVER (PARTITION BY cpf ORDER BY ts_touch) AS passo_3,
    LEAD(ts_touch, 2) OVER (PARTITION BY cpf ORDER BY ts_touch) AS ts_passo_3
  FROM digital_tp
),

-- 4. CONSOLIDAÇÃO DA JORNADA
jornadas_paciente AS (
  SELECT
    cpf,
    ts_touch AS inicio_jornada,
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

-- 5. O MUNDO TRANSACIONAL (PRODUTOS)
dados_transacionais AS (
  SELECT
    nu_cpf_paciente AS cpf,
    dt_criacao_agendamento,
    id_agendamento,
    origem_operador_agendamento AS canal_final,
    nm_marca_unidade,
    nm_exame,
    EXTRACT(YEAR FROM CURRENT_DATE()) - EXTRACT(YEAR FROM dt_nasc_paciente) AS idade_paciente,
    flg_agendabilidade AS tipo_encaixe,
    IF(UPPER(st_agendamento) = 'BOOKED', SAFE_CAST(valor_projetado_exame AS NUMERIC), 0) AS receita_agendamento
  FROM `company-bi-prd.ds_datamart_agendamento.fct_datamart_agendamento`
  WHERE dt_criacao_agendamento >= dt_ini AND nu_cpf_paciente IS NOT NULL
)

-- 6. VISÃO EXECUTIVA FINANCEIRA E CLÍNICA
SELECT
  j.tipo_jornada,
  COALESCE(t.canal_final, 'UNIDADES') AS canal_de_conversao,
  t.nm_marca_unidade AS marca,
  t.nm_exame AS exame,
  t.tipo_encaixe,
  CASE 
    WHEN t.idade_paciente < 18 THEN '0-17 anos'
    WHEN t.idade_paciente BETWEEN 18 AND 35 THEN '18-35 anos'
    WHEN t.idade_paciente BETWEEN 36 AND 55 THEN '36-55 anos'
    WHEN t.idade_paciente > 55 THEN '56+ anos'
    ELSE 'Não Informado'
  END AS faixa_etaria,
  
  COUNT(DISTINCT j.cpf) AS volume_pacientes_convertidos,
  COUNT(DISTINCT t.id_agendamento) AS qtd_carrinhos_fechados,
  
  ROUND(SUM(t.receita_agendamento), 2) AS receita_bruta_total,
  
  ROUND(COUNT(DISTINCT j.cpf) * 
    CASE 
      WHEN j.tipo_jornada LIKE '%Paid Search%' THEN 0.77 
      WHEN j.tipo_jornada LIKE '%CRM Marketing%' THEN 0.16 
    ELSE 0 
  END, 2) AS investimento_estimado,
  
  -- LIFT FINANCEIRO
  ROUND(SUM(t.receita_agendamento * 
    CASE 
      WHEN j.tipo_jornada LIKE '%Paid Search%' THEN 0.275 -- Lift de Paid Search → 1 – (1/1,38) = 27,5%
      WHEN j.tipo_jornada LIKE '%CRM Marketing%' THEN 0.219 -- Lift de CRM MKT → 1 – (1/1,28) = 21,9%
      WHEN j.tipo_jornada LIKE '%Direto%' THEN 0.275 -- Lift de Direto → 1 – (1/1,38) = 27,5%
      ELSE 0
    END
  ), 2) AS receita_incremental_lift

FROM jornadas_paciente j
INNER JOIN dados_transacionais t ON j.cpf = t.cpf AND t.dt_criacao_agendamento BETWEEN DATETIME(j.inicio_jornada) AND DATETIME_ADD(DATETIME(j.inicio_jornada), INTERVAL 5 DAY)
GROUP BY ALL
HAVING receita_bruta_total > 0
ORDER BY receita_bruta_total DESC