-- ANÁLISE COMPLETA EM QUERY ÚNICA — PAID SEARCH PÓS-LOGIN

-- para atualizar nos próximos meses basta trocar as datas nos 4 pontos marcados


WITH 

--TROCAR DATAS AQUI (4 lugares) 
-- Período: '2026-01-01' AND '2026-06-29'


-- 1. Sessões deslogadas do período
sessoes_deslogadas AS (
  SELECT
    id_navigation_session,
    id_patient_mdm,
    dt_reference,
    SPLIT(id_navigation_session, ':')[OFFSET(0)] AS user_pseudo_id,
    ds_channel_group,
    ds_campaign,
    cd_device_category,
    dt_session_start,
    dt_session_end
  FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_onboarding_em_numeros`
  WHERE dt_reference BETWEEN '2026-01-01' AND '2026-06-29'  -- DATA 1
    AND (in_step_success_login IS NULL OR in_step_success_login = 0)
),

-- 2. Histórico de login (quem já logou alguma vez)
historico_login AS (
  SELECT
    SPLIT(id_navigation_session, ':')[OFFSET(0)] AS user_pseudo_id,
    ARRAY_AGG(id_patient_mdm ORDER BY dt_reference DESC LIMIT 1)[OFFSET(0)] AS mdm_historico
  FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_onboarding_em_numeros`
  WHERE in_step_success_login >= 1
    AND dt_reference < '2026-06-29'  -- DATA 2 (dia seguinte ao fim do período)
    AND id_patient_mdm IS NOT NULL
    AND TRIM(CAST(id_patient_mdm AS STRING)) != ''
  GROUP BY 1
),

-- 3. Login por CPF no mesmo dia (cross-device)
login_mesmo_dia_cpf AS (
  SELECT
    COALESCE(REPLACE(c.main_key, 'CPF|', ''), cip.pac_cpf) AS cpf,
    o.dt_reference
  FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_onboarding_em_numeros` o
  LEFT JOIN `app-prd.ds_trusted_dataform_cadastro_mdm.tb_trusted_tel_cadastro-mdm-people` c
    ON NULLIF(TRIM(CAST(o.id_patient_mdm AS STRING)), '') = c.id
  LEFT JOIN `interoper-dataplatform-prd.refined_gliese.gliese_pac` cip
    ON REPLACE(c.main_key, 'CPF|', '') IS NULL
    AND CAST(o.id_patient_mdm AS STRING) = CAST(cip.pac_cip AS STRING)
  WHERE o.dt_reference BETWEEN '2026-01-01' AND '2026-06-29'  -- DATA 3
    AND o.in_step_success_login >= 1
    AND COALESCE(REPLACE(c.main_key, 'CPF|', ''), cip.pac_cpf) IS NOT NULL
  GROUP BY 1, 2
),

-- 4. Cadastro paciente (resolve MDM → CPF)
cadastro_paciente AS (
  SELECT id, REPLACE(main_key, 'CPF|', '') AS cpf
  FROM `app-prd.ds_trusted_dataform_cadastro_mdm.tb_trusted_tel_cadastro-mdm-people`
),

cadastro_por_cip AS (
  SELECT CAST(pac_cip AS STRING) AS pac_cip, pac_cpf
  FROM `interoper-dataplatform-prd.refined_gliese.gliese_pac`
  WHERE pac_cpf IS NOT NULL AND TRIM(pac_cpf) != ''
  GROUP BY 1, 2
),

-- 5. Histórico login por CPF (cross-device)
historico_login_por_cpf AS (
  SELECT COALESCE(cp.cpf, cip.pac_cpf) AS cpf
  FROM historico_login h
  LEFT JOIN cadastro_paciente cp ON NULLIF(TRIM(CAST(h.mdm_historico AS STRING)), '') = cp.id
  LEFT JOIN cadastro_por_cip cip ON cp.cpf IS NULL AND CAST(h.mdm_historico AS STRING) = cip.pac_cip
  WHERE COALESCE(cp.cpf, cip.pac_cpf) IS NOT NULL
  GROUP BY 1
),

-- 6. Sessões deslogadas enriquecidas com CPF + flags
sessoes_enriquecidas AS (
  SELECT
    s.id_navigation_session,
    s.dt_reference,
    s.user_pseudo_id,
    s.ds_channel_group,
    s.ds_campaign,
    s.cd_device_category,
    s.dt_session_start,
    s.dt_session_end,
    COALESCE(c.cpf, cip.pac_cpf) AS cpf,
    COALESCE(NULLIF(TRIM(CAST(s.id_patient_mdm AS STRING)), ''), h.mdm_historico) AS id_patient_mdm,
    -- Login histórico: por user_pseudo_id OU por CPF
    CASE WHEN h.user_pseudo_id IS NOT NULL OR hcpf.cpf IS NOT NULL THEN 1 ELSE 0 END AS in_login_historico,
    -- Logou mesmo dia: por user_pseudo_id OU por CPF (cross-device)
    CASE WHEN d.user_pseudo_id IS NOT NULL OR ld_cpf.cpf IS NOT NULL THEN 1 ELSE 0 END AS in_logou_mesmo_dia
  FROM sessoes_deslogadas s
  LEFT JOIN historico_login h ON s.user_pseudo_id = h.user_pseudo_id
  LEFT JOIN cadastro_paciente c 
    ON COALESCE(NULLIF(TRIM(CAST(s.id_patient_mdm AS STRING)), ''), h.mdm_historico) = c.id
  LEFT JOIN cadastro_por_cip cip 
    ON c.cpf IS NULL 
    AND CAST(COALESCE(NULLIF(TRIM(CAST(s.id_patient_mdm AS STRING)), ''), h.mdm_historico) AS STRING) = cip.pac_cip
  LEFT JOIN historico_login_por_cpf hcpf ON COALESCE(c.cpf, cip.pac_cpf) = hcpf.cpf
  -- Login mesmo dia por user_pseudo_id
  LEFT JOIN (
    SELECT SPLIT(id_navigation_session, ':')[OFFSET(0)] AS user_pseudo_id, dt_reference
    FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_onboarding_em_numeros`
    WHERE in_step_success_login >= 1
      AND dt_reference BETWEEN '2026-01-01' AND '2026-06-29'  -- DATA 4
    GROUP BY 1, 2
  ) d ON s.user_pseudo_id = d.user_pseudo_id AND s.dt_reference = d.dt_reference
  -- Login mesmo dia por CPF (cross-device)
  LEFT JOIN login_mesmo_dia_cpf ld_cpf 
    ON COALESCE(c.cpf, cip.pac_cpf) = ld_cpf.cpf 
    AND s.dt_reference = ld_cpf.dt_reference
),

-- 7. Primeiro login do dia (com flag de agendamento)
primeiro_login AS (
  SELECT 
    COALESCE(REPLACE(c.main_key, 'CPF|', ''), cip.pac_cpf) AS cpf,
    o.dt_reference,
    MIN(o.dt_session_start) AS ts_primeiro_login,
    MAX(CASE WHEN agd.in_step_scheduling >= 1 THEN 1 ELSE 0 END) AS fez_agendamento
  FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_onboarding_em_numeros` o
  LEFT JOIN `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_agd_em_numeros` agd
    ON o.id_navigation_session = agd.id_navigation_session
  LEFT JOIN `app-prd.ds_trusted_dataform_cadastro_mdm.tb_trusted_tel_cadastro-mdm-people` c
    ON NULLIF(TRIM(CAST(o.id_patient_mdm AS STRING)), '') = c.id
  LEFT JOIN `interoper-dataplatform-prd.refined_gliese.gliese_pac` cip
    ON REPLACE(c.main_key, 'CPF|', '') IS NULL
    AND CAST(o.id_patient_mdm AS STRING) = CAST(cip.pac_cip AS STRING)
  WHERE o.in_step_success_login >= 1
    AND o.dt_session_start IS NOT NULL
    AND o.dt_reference BETWEEN '2026-01-01' AND '2026-06-29'
    AND COALESCE(REPLACE(c.main_key, 'CPF|', ''), cip.pac_cpf) IS NOT NULL
  GROUP BY 1, 2
),

-- 8. Sessões deslogadas pós-login (só quem tem histórico + logou no dia)
sessoes_pos_login AS (
  SELECT
    FORMAT_DATE('%Y-%m', se.dt_reference) AS mes,
    se.cpf,
    se.id_navigation_session,
    se.ds_channel_group,
    se.ds_campaign,
    pl.fez_agendamento,
    TIMESTAMP_DIFF(
      CAST(se.dt_session_start AS TIMESTAMP),
      CAST(pl.ts_primeiro_login AS TIMESTAMP),
      MINUTE
    ) AS minutos_apos_login
  FROM sessoes_enriquecidas se
  INNER JOIN primeiro_login pl
    ON se.cpf = pl.cpf
    AND se.dt_reference = pl.dt_reference
  WHERE se.in_login_historico = 1
    AND se.in_logou_mesmo_dia = 1
    AND se.cpf IS NOT NULL AND TRIM(se.cpf) != ''
    AND se.dt_session_start IS NOT NULL
    AND CAST(se.dt_session_start AS TIMESTAMP) > CAST(pl.ts_primeiro_login AS TIMESTAMP)
)

-- RESULTADO (delta calculado vs baseline out/25-fev/26)
SELECT 
  mes,
  total_pac_pos_login,
  total_sess_pos_login,
  ps_sessoes,
  ROUND((ps_sessoes / 185858.0 - 1) * 100, 1) AS ps_sessoes_delta_vs_media,
  ps_pacientes,
  ROUND((ps_pacientes / 98067.0 - 1) * 100, 1) AS ps_pacientes_delta_vs_media,
  ps_pct_pacientes,
  ps_custo_estimado,
  ps_agendou_pacientes,
  ps_agendou_sessoes,
  ps_pct_agendou,
  ps_agendou_custo
FROM (
  SELECT 
    mes,
    COUNT(DISTINCT cpf) AS total_pac_pos_login,
    COUNT(DISTINCT id_navigation_session) AS total_sess_pos_login,
    COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' THEN cpf END) AS ps_pacientes,
    COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' THEN id_navigation_session END) AS ps_sessoes,
    ROUND(
      COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' THEN cpf END) * 100.0 /
      NULLIF(COUNT(DISTINCT cpf), 0)
    , 1) AS ps_pct_pacientes,
    ROUND(COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' THEN id_navigation_session END) * 0.77) AS ps_custo_estimado,
    COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' AND fez_agendamento = 1 THEN cpf END) AS ps_agendou_pacientes,
    COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' AND fez_agendamento = 1 THEN id_navigation_session END) AS ps_agendou_sessoes,
    ROUND(
      COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' AND fez_agendamento = 1 THEN cpf END) * 100.0 /
      NULLIF(COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' THEN cpf END), 0)
    , 1) AS ps_pct_agendou,
    ROUND(COUNT(DISTINCT CASE WHEN ds_channel_group = 'Paid Search' AND fez_agendamento = 1 THEN id_navigation_session END) * 0.77) AS ps_agendou_custo
  FROM sessoes_pos_login
  GROUP BY mes
)
ORDER BY mes