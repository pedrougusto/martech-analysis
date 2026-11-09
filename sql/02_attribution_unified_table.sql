--CREATE OR REPLACE TABLE `analytics-project.analytics_sandbox.tb_atribuicao_final`
--PARTITION BY dt_atendimento AS

WITH
params AS (
  SELECT DATE '2025-01-01' AS dt_ini, CURRENT_DATE() AS dt_fim, 30 AS janela_dias
),

atendimentos AS (
  SELECT
    CAST(id_atendimento AS STRING) AS id_atendimento,
    CAST(id_mdm_paciente AS STRING) AS id_paciente,
    CAST(nu_cpf_paciente AS STRING) AS cpf,
    dt_atendimento,
    SUM(vl_recebido_atendimento) AS receita
  FROM `company-bi-prd.ds_datamart_atendimento.fct_datamart_atendimento`
  WHERE dt_atendimento BETWEEN (SELECT dt_ini FROM params) AND (SELECT dt_fim FROM params)
    AND nm_mercado_unidade IN ('PRIVADO','PREMIUM')
    AND handle_fato_excluido='NAO'
  GROUP BY 1,2,3,4
),

agendamentos AS (
  SELECT
    DATE(a.dt_criacao_agendamento) AS dt_agd,
    a.dt_criacao_agendamento,
    CAST(a.id_paciente AS STRING) AS id_paciente,
    CAST(a.id_agendamento AS STRING) AS id_agendamento,
    CAST(id_atendimento_final AS STRING) AS id_atendimento,
    UPPER(a.origem_operador_agendamento) AS origem_operador_agendamento
  FROM `company-bi-prd.ds_datamart_agendamento.fct_datamart_agendamento` a,
  UNNEST(SPLIT(COALESCE(a.id_atendimento_realizado_paciente, a.id_atendimento_realizado, a.id_atendimento_agenda), ';')) AS id_atendimento_final
  WHERE dt_criacao_agendamento BETWEEN DATE_SUB((SELECT dt_ini FROM params), INTERVAL 30 DAY) AND (SELECT dt_fim FROM params)
    AND id_atendimento_final IS NOT NULL
    AND CAST(id_atendimento_final AS STRING) != ''
    AND a.st_agendamento <> 'CANCELLED'
),

has_agd AS (
  SELECT DISTINCT id_atendimento, 1 AS has_agd
  FROM agendamentos
),

last_agd AS (
  SELECT
    agd.id_atendimento,
    agd.id_paciente,
    agd.origem_operador_agendamento,
    agd.id_agendamento,
    agd.dt_criacao_agendamento,
    agd.dt_agd,
    atd.receita
  FROM agendamentos agd
  JOIN atendimentos atd USING (id_atendimento)
  WHERE agd.dt_agd BETWEEN DATE_SUB(atd.dt_atendimento, INTERVAL (SELECT janela_dias FROM params) DAY) AND atd.dt_atendimento
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY agd.id_atendimento
    ORDER BY agd.dt_criacao_agendamento DESC, agd.id_agendamento DESC
  ) = 1
),

agd_to_session AS (
  SELECT
    CAST(id_agendamento AS STRING) AS id_agendamento,
    sessionid
  FROM `analytics-project.ds_dimfacto_dataform_app_pac_attribution.tb_fact_ga_app_pac_plus_datamart_agd`
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY CAST(id_agendamento AS STRING)
    ORDER BY sessionid DESC
  ) = 1
),

tp_base AS (
  SELECT
    CAST(id_paciente AS STRING) AS id_paciente,
    dt_touch,
    ts_touch,
    UPPER(canal) AS canal,
    subcanal,
    origem_id
  FROM `analytics-project.analytics_sandbox.vw_touchpoints_unificados_digital_nac`
  WHERE dt_touch BETWEEN DATE_SUB((SELECT dt_ini FROM params), INTERVAL (SELECT janela_dias FROM params) DAY) AND (SELECT dt_fim FROM params)
),

session_to_subcanal AS (
  SELECT
    origem_id AS sessionid,
    ARRAY_AGG(subcanal ORDER BY dt_touch DESC LIMIT 1)[OFFSET(0)] AS subcanal
  FROM tp_base
  WHERE canal = 'DIGITAL'
    AND origem_id IS NOT NULL
  GROUP BY 1
),

nac_tp_rank AS (
  SELECT
    l.id_atendimento,
    t.subcanal AS nac_subcanal
  FROM last_agd l
  JOIN tp_base t
    ON t.id_paciente = l.id_paciente
   AND t.canal = 'NAC'
  WHERE t.dt_touch BETWEEN DATE_SUB(l.dt_agd, INTERVAL (SELECT janela_dias FROM params) DAY) AND l.dt_agd
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY l.id_atendimento
    ORDER BY DATE_DIFF(l.dt_agd, t.dt_touch, DAY) ASC, t.ts_touch DESC
  ) = 1
),

last_agd_canal AS (
  SELECT
    l.id_atendimento,
    CASE
      WHEN l.origem_operador_agendamento IN ('DIGITAL','NAC','UNIDADES')
        THEN l.origem_operador_agendamento
      ELSE 'UNIDADES'
    END AS canal_last_agd,
    CASE
      WHEN l.origem_operador_agendamento = 'DIGITAL'
        THEN COALESCE(ss.subcanal, 'Direto')
      WHEN l.origem_operador_agendamento = 'NAC'
        THEN COALESCE(nr.nac_subcanal, 'Receptivo Voz')
      ELSE 'Balcao'
    END AS subcanal_last_agd,
    l.receita
  FROM last_agd l
  LEFT JOIN agd_to_session ats
    ON l.id_agendamento = ats.id_agendamento
  LEFT JOIN session_to_subcanal ss
    ON ats.sessionid = ss.sessionid
  LEFT JOIN nac_tp_rank nr
    ON l.id_atendimento = nr.id_atendimento
),

atend_flag AS (
  SELECT
    a.*,
    COALESCE(h.has_agd, 0) AS has_agd
  FROM atendimentos a
  LEFT JOIN has_agd h USING (id_atendimento)
),

tp_jornada AS (
  SELECT
    a.id_atendimento,
    a.id_paciente,
    a.dt_atendimento,
    a.receita,
    a.has_agd,
    t.canal,
    t.subcanal,
    t.origem_id,
    t.dt_touch,
    t.ts_touch,
    DATE_DIFF(a.dt_atendimento, t.dt_touch, DAY) AS dias_antes
  FROM atend_flag a
  JOIN tp_base t
    ON t.id_paciente = a.id_paciente
  WHERE t.dt_touch BETWEEN DATE_SUB(a.dt_atendimento, INTERVAL (SELECT janela_dias FROM params) DAY) AND a.dt_atendimento
),

tp_dedup AS (
  SELECT *
  FROM tp_jornada
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY id_atendimento, canal, subcanal
    ORDER BY dt_touch DESC, ts_touch DESC, origem_id DESC
  ) = 1
),

atend_com_tp AS (
  SELECT DISTINCT id_atendimento
  FROM tp_dedup
),

tp_final AS (
  SELECT
    id_atendimento,
    id_paciente,
    dt_atendimento,
    receita,
    canal,
    subcanal,
    origem_id,
    dt_touch,
    ts_touch,
    dias_antes
  FROM tp_dedup

  UNION ALL
  SELECT
    a.id_atendimento,
    a.id_paciente,
    a.dt_atendimento,
    a.receita,
    'UNIDADES' AS canal,
    'Balcao' AS subcanal,
    CAST(NULL AS STRING) AS origem_id,
    a.dt_atendimento AS dt_touch,
    TIMESTAMP(a.dt_atendimento) AS ts_touch,
    0 AS dias_antes
  FROM atend_flag a
  LEFT JOIN atend_com_tp x USING (id_atendimento)
  WHERE x.id_atendimento IS NULL
),

tp_peso AS (
  SELECT
    t.*,
    (1 / (t.dias_antes + 1)) AS proximidade,
    GREATEST(COALESCE(e.eficiencia, 0.01), 0.01) AS eficiencia,
    GREATEST(COALESCE(e.eficiencia, 0.01), 0.01) * (1 / (t.dias_antes + 1)) AS peso_bruto
  FROM tp_final t
  LEFT JOIN `analytics-project.analytics_sandbox.vw_eficiencia_canal_subcanal_90d` e
    ON UPPER(t.canal) = UPPER(e.canal)
   AND t.subcanal = e.subcanal
),

final_dd AS (
  SELECT
    * ,
    SAFE_DIVIDE(peso_bruto, SUM(peso_bruto) OVER (PARTITION BY id_atendimento)) AS peso_normalizado,
    SAFE_DIVIDE(peso_bruto, SUM(peso_bruto) OVER (PARTITION BY id_atendimento)) * receita AS receita_atribuida
  FROM tp_peso
),

final_out AS (
  SELECT
    f.*,
    COALESCE(la.canal_last_agd, 'UNIDADES') AS canal_last_agd,
    COALESCE(la.subcanal_last_agd, 'Balcao') AS subcanal_last_agd,
    CASE
      WHEN ROW_NUMBER() OVER (
        PARTITION BY f.id_atendimento
        ORDER BY
          COALESCE(la.canal_last_agd, 'UNIDADES'),
          COALESCE(la.subcanal_last_agd, 'Balcao'),
          f.id_atendimento
      ) = 1
      THEN COALESCE(la.receita, f.receita)
      ELSE 0
    END AS receita_last_agd
  FROM final_dd f
  LEFT JOIN last_agd_canal la USING (id_atendimento)
),

-- CRM como entidade analítica
base_receita_crm AS (
  SELECT
    cip_visita AS id_atendimento,
    dt_atendimento,
    data_envio,
    "CRM" AS origem_campanha,
    LOWER(nome_jornada) AS nome_campanha,
    canal AS canal_crm,
    CASE
      WHEN LOWER(canal) LIKE '%sms%' THEN 'SMS'
      WHEN abertura = 'SIM' THEN 'Interagiu'
      ELSE 'Não interagiu'
    END AS grupo_interacao,
    CASE
      WHEN ((LOWER(nome_jornada) LIKE 'crcr%' OR LOWER(nome_jornada) LIKE 'crmcore%')) THEN 'Marketing'
      ELSE 'Transacional'
    END AS tipo_crm
  FROM `company-bi-prd.ds_datamart_marketing.fct_atribuicao_receita`
  WHERE dt_atendimento BETWEEN (SELECT dt_ini FROM params) AND (SELECT dt_fim FROM params)
  GROUP BY ALL
),

base_receita_crm_1row AS (
  SELECT
    id_atendimento,
    ANY_VALUE(dt_atendimento) AS dt_atendimento,
    (ARRAY_AGG(STRUCT(
        data_envio,
        origem_campanha,
        nome_campanha,
        canal_crm,
        grupo_interacao,
        tipo_crm
      )
      ORDER BY data_envio DESC
      LIMIT 1
    ))[OFFSET(0)] AS campanha_rep
  FROM base_receita_crm
  GROUP BY 1
),

base_receita_crm_flat AS (
  SELECT
    id_atendimento,
    dt_atendimento,
    campanha_rep.data_envio AS data_envio,
    campanha_rep.origem_campanha AS origem_campanha,
    campanha_rep.nome_campanha AS nome_campanha,
    campanha_rep.canal_crm AS canal_crm,
    campanha_rep.grupo_interacao AS grupo_interacao,
    campanha_rep.tipo_crm AS tipo_crm
  FROM base_receita_crm_1row
),

tb_final_atribuicao AS (
  SELECT
    ch.id_atendimento,
    atd.cpf,
    ch.dt_atendimento,
    ch.canal,
    ch.subcanal,
    crm.origem_campanha,
    crm.tipo_crm,
    crm.data_envio,
    crm.nome_campanha,
    crm.grupo_interacao,
    crm.canal_crm,
    ch.dt_touch,
    ch.dias_antes,
    ch.eficiencia,
    ch.proximidade,
    ch.peso_bruto,
    ch.peso_normalizado,
    ch.receita_atribuida,
    ch.canal_last_agd,
    ch.subcanal_last_agd,
    ch.receita_last_agd
  FROM final_out ch
  LEFT JOIN base_receita_crm_flat crm
    ON ch.id_atendimento = crm.id_atendimento
  LEFT JOIN atendimentos atd
    ON ch.id_atendimento = atd.id_atendimento
),

-- Inclusão CRM como subcanal de NAC e UNIDADES
tp_pos AS (
  SELECT 
    *,
    CASE
      WHEN origem_campanha = 'CRM'
        AND data_envio IS NOT NULL
        AND dt_touch >= data_envio
      THEN 1 ELSE 0
    END AS tp_pos_campanha,
    DATE_DIFF(dt_touch, data_envio, DAY) AS dias_antes_envio
  FROM tb_final_atribuicao
),

ordem_pos AS (
  SELECT
    *,
    CASE
      WHEN tp_pos_campanha = 1 THEN
        ROW_NUMBER() OVER (
          PARTITION BY id_atendimento
          ORDER BY dt_touch ASC, eficiencia DESC
        )
    END AS ordem_pos_campanha
  FROM tp_pos
),

flags_linha AS (
  SELECT
    *,
    CASE WHEN (canal='NAC' AND origem_campanha='CRM' AND ordem_pos_campanha=1) THEN 1 ELSE 0 END AS nac_crm_linha,
    CASE WHEN (canal='UNIDADES' AND origem_campanha='CRM' AND dias_antes_envio<=30) THEN 1 ELSE 0 END AS unidades_crm_linha
  FROM ordem_pos
),

flags_atd AS (
  SELECT
    id_atendimento,
    MAX(nac_crm_linha) AS nac_crm_atd,
    MAX(unidades_crm_linha) AS unidades_crm_atd,
    ANY_VALUE(tipo_crm) AS tipo_crm_atd
  FROM flags_linha
  GROUP BY 1
),

final AS (
  SELECT
    f.*,
    a.nac_crm_atd,
    a.unidades_crm_atd,
    a.tipo_crm_atd,
    CASE 
      WHEN ((f.nac_crm_linha=1 OR f.unidades_crm_linha=1) AND f.tipo_crm='Marketing') THEN 'CRM Marketing'
      WHEN ((f.nac_crm_linha=1 OR f.unidades_crm_linha=1) AND f.tipo_crm='Transacional') THEN 'CRM Transacional'
      ELSE f.subcanal
    END AS subcanal_data_driven_ajustado,
    CASE
      WHEN f.canal_last_agd = 'NAC' AND a.nac_crm_atd = 1 THEN
        CASE WHEN a.tipo_crm_atd='Marketing' THEN 'CRM Marketing'
          WHEN a.tipo_crm_atd='Transacional' THEN 'CRM Transacional'
          ELSE f.subcanal_last_agd
        END
      WHEN f.canal_last_agd = 'UNIDADES' AND a.unidades_crm_atd = 1 THEN
        CASE WHEN a.tipo_crm_atd='Marketing' THEN 'CRM Marketing'
          WHEN a.tipo_crm_atd='Transacional' THEN 'CRM Transacional'
          ELSE f.subcanal_last_agd
        END
      ELSE f.subcanal_last_agd
    END AS subcanal_last_agd_ajustado
  FROM flags_linha f
  LEFT JOIN flags_atd a USING (id_atendimento)
)

SELECT
  id_atendimento,
  cpf,
  dt_atendimento,
  -- Data driven
  canal,
  subcanal_data_driven_ajustado AS subcanal,
  origem_campanha,
  tipo_crm,
  data_envio,
  nome_campanha,
  grupo_interacao,
  canal_crm,
  dt_touch,
  dias_antes,
  eficiencia,
  proximidade,
  peso_bruto,
  peso_normalizado,
  receita_atribuida,
  -- Last AGD
  canal_last_agd,
  subcanal_last_agd_ajustado AS subcanal_last_agd,
  receita_last_agd
FROM final