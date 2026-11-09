DECLARE dt_ini DATE DEFAULT '2026-01-01';
DECLARE dt_fim DATE DEFAULT '2026-06-30';
DECLARE janela_horas INT64 DEFAULT 48;

-- 1. IDENTIFICAÇÃO DO PACIENTE (MDM)
WITH cpf_match AS (
  SELECT CAST(id AS STRING) AS id_paciente, REGEXP_EXTRACT(main_key, r"[0-9]{11}") AS cpf
  FROM `app-prd.ds_trusted_dataform_cadastro_mdm.tb_trusted_tel_cadastro-mdm-people`
  WHERE REGEXP_EXTRACT(main_key, r"[0-9]{11}") IS NOT NULL
),

-- 2. TOUCHPOINTS DIGITAIS E EXTRAÇÃO DA CAMPANHA
digital_tp AS (
  SELECT
    m.cpf,
    a.data AS dt_touch,
    DATETIME(TIMESTAMP_MICROS(a.first_event_timestamp), 'America/Sao_Paulo') AS ts_touch,
    EXTRACT(HOUR FROM DATETIME(TIMESTAMP_MICROS(a.first_event_timestamp), 'America/Sao_Paulo')) AS hora_touch,
    a.campaign,
    CASE
      WHEN (LOWER(a.medium) IN ('cpc','cpm','paid') OR LOWER(a.source) IN ('cpc','cpm','paid') OR LOWER(a.source) LIKE '%cpc%' OR LOWER(a.medium) LIKE '%cpc%') AND LOWER(a.source) NOT IN ('facebook','instagram','tiktok','twitter') THEN 'Paid Search'
      WHEN (LOWER(a.source) LIKE '%direct%' AND LOWER(a.medium) LIKE '%none%') OR LOWER(a.source) = '(not set)' OR LOWER(a.medium) = '(not set)' THEN 'Direto'
      ELSE NULL
    END AS subcanal
  FROM `analytics-project.ds_dimfacto_dataform_app_pac_attribution.tb_dim_ga_app_pac_attribution_last_click` a
  LEFT JOIN cpf_match m ON CAST(a.user_id AS STRING) = m.id_paciente
  WHERE a.data BETWEEN dt_ini AND dt_fim AND m.cpf IS NOT NULL 
  GROUP BY ALL
  HAVING subcanal IN ('Paid Search', 'Direto')
),

-- 3. SEQUENCIAMENTO DOS PASSOS (ARRASTANDO OS TIMESTAMPS)
sequenciado AS (
  SELECT *,
    LEAD(subcanal, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS passo_2,
    LEAD(ts_touch, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS ts_passo_2,
    LEAD(hora_touch, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS hora_passo_2,
    LEAD(campaign, 1) OVER (PARTITION BY cpf ORDER BY ts_touch) AS campaign_passo_2
  FROM digital_tp
),

-- 4. IDENTIFICAÇÃO DOS CAMINHOS ALVO DENTRO DE 48H
jornadas_alvo AS (
  SELECT
    cpf,
    ts_touch AS ts_passo_1,
    ts_passo_2,
    hora_passo_2,
    CASE 
      WHEN subcanal = 'Direto' AND passo_2 = 'Paid Search' AND DATETIME_DIFF(ts_passo_2, ts_touch, HOUR) <= janela_horas THEN 'Direto > Paid Search'
      WHEN subcanal = 'Paid Search' AND passo_2 = 'Direto' AND DATETIME_DIFF(ts_passo_2, ts_touch, HOUR) <= janela_horas THEN 'Paid Search > Direto'
      ELSE NULL
    END AS tipo_jornada,
    
    -- O nome da campanha do Google, não importa se foi no passo 1 ou 2
    CASE 
      WHEN subcanal = 'Direto' AND passo_2 = 'Paid Search' THEN campaign_passo_2
      WHEN subcanal = 'Paid Search' AND passo_2 = 'Direto' THEN campaign
      ELSE 'N/A'
    END AS campanha_envolvida

  FROM sequenciado
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cpf, DATE(ts_touch) ORDER BY ts_touch ASC) = 1
),

-- 5. O MUNDO TRANSACIONAL (Agendamentos e No-Show)
transacional_resumo AS (
  SELECT 
    nu_cpf_paciente AS cpf,
    DATETIME(dt_criacao_agendamento) AS dt_agendamento,
    id_agendamento,
    CASE WHEN UPPER(noshow_ficha) = 'SIM' AND UPPER(noshow_por_paciente) = 'SIM' AND UPPER(st_agendamento) = 'BOOKED' THEN 1 ELSE 0 END AS flag_no_show,
  IF(UPPER(st_agendamento) = 'BOOKED', SAFE_CAST(valor_projetado_exame AS NUMERIC), 0) AS receita_agendamento
  FROM `company-bi-prd.ds_datamart_agendamento.fct_datamart_agendamento`
  WHERE dt_criacao_agendamento >= dt_ini AND nu_cpf_paciente IS NOT NULL
),

-- 6. CRUZAMENTO INTRA-JORNADA (Aqui a mágica acontece!)
cruzamento_fatiado AS (
  SELECT
    j.tipo_jornada,
    j.campanha_envolvida,
    j.hora_passo_2,
    j.cpf,
    ROUND(SUM(t.receita_agendamento),2) AS receita_agendamento,
    
    -- Agendamentos que ocorreram NO PASSO 1 (Antes do Passo 2)
    COUNT(DISTINCT CASE WHEN t.dt_agendamento >= j.ts_passo_1 AND t.dt_agendamento < j.ts_passo_2 THEN t.id_agendamento END) AS agendamentos_no_passo_1,
    SUM(CASE WHEN t.dt_agendamento >= j.ts_passo_1 AND t.dt_agendamento < j.ts_passo_2 THEN t.flag_no_show ELSE 0 END) AS no_show_passo_1,
    
    -- Agendamentos que ocorreram NO PASSO 2 (No momento ou logo após o segundo clique)
    COUNT(DISTINCT CASE WHEN t.dt_agendamento >= j.ts_passo_2 AND t.dt_agendamento <= DATETIME_ADD(j.ts_passo_1, INTERVAL 5 DAY) THEN t.id_agendamento END) AS agendamentos_no_passo_2
    
  FROM jornadas_alvo j
  LEFT JOIN transacional_resumo t ON j.cpf = t.cpf
  WHERE j.tipo_jornada IS NOT NULL
  GROUP BY ALL
)

-- 7. VISÃO EXECUTIVA (Respondendo as Perguntas de Negócio)
SELECT
  tipo_jornada,
  COALESCE(campanha_envolvida, 'Não Mapeada') AS campanhas,
  
  -- Agrupamento do Horário em que ocorreu o SEGUNDO clique
  CASE 
    WHEN hora_passo_2 BETWEEN 6 AND 11 THEN 'Manhã (06-11h)'
    WHEN hora_passo_2 BETWEEN 12 AND 17 THEN 'Tarde (12-17h)'
    WHEN hora_passo_2 BETWEEN 18 AND 23 THEN 'Noite (18-23h)'
    ELSE 'Madrugada (00-05h)'
  END AS horario_do_segundo_touch,
  
  no_show_passo_1,
  COUNT(DISTINCT cpf) AS volume_pacientes,
  SUM(agendamentos_no_passo_1) AS volume_conversoes_iniciais,
  SUM(agendamentos_no_passo_2) AS volume_upsell_ou_reagendamento,
  
  ROUND(SAFE_DIVIDE(SUM(no_show_passo_1), SUM(agendamentos_no_passo_1)), 2) AS taxa_no_show_conversao_inicial,

  ROUND(SUM(receita_agendamento),2) AS receita_agendamento

FROM cruzamento_fatiado
-- FILTRO VITAL: Só mostra quem converteu no PASSO 1
WHERE agendamentos_no_passo_1 > 0 
GROUP BY ALL
ORDER BY tipo_jornada, volume_pacientes DESC
