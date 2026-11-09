DECLARE dt_ini DATE DEFAULT '2026-07-01';
DECLARE dt_fim DATE DEFAULT '2026-07-21';

WITH campanhas AS (
  SELECT *
  FROM UNNEST([
    'f002_marca_d_facebook_multiplos_agendamento_conversao_app',
    'f004_marca_d_facebook_multiplos_vacinas_conversao_app',
    'f006_marca_d_facebook_multiplos_domiciliar_conversao_app',
    'g002_marca_d_google_pmax_agendamento_conversao_app_teste',
    'g002_marca_d_google_search_agendamento_conversao_app_teste',
    'g004_marca_d_google_search_vacinas_gerais_conversao_app_teste',
    'g006_marca_d_google_pmax_atendimento-domiciliar_conversao_app_teste',
    'g006_marca_d_google_search_coleta-domiciliar_conversao_app_teste'
  ]) AS campanha
),

-- O FUNIL AGORA É NOSSA BASE (1 linha por sessao APP)
funil AS (
  SELECT
    id_navigation_session,
    LOWER(ds_campaign)      AS campanha,
    ANY_VALUE(ds_source)    AS source, -- Assumindo que a coluna origem/source exista na tabela
    MAX(in_step_patient)    AS step_paciente,
    MAX(in_step_exams)      AS step_exames,
    MAX(in_step_unit)       AS step_unidade,
    MAX(in_step_date_hour)  AS step_data_hora,
    MAX(in_step_scheduling) AS step_agendou
  FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_agd_em_numeros`
  WHERE dt_reference BETWEEN dt_ini AND dt_fim
    AND LOWER(ds_campaign) IN (SELECT campanha FROM campanhas)
  GROUP BY id_navigation_session, ds_campaign
),

-- booking_id -> sessao APP (1 linha por booking)
bookings AS (
  SELECT
    booking_id AS id_agendamento,
    f.id_navigation_session
  FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_agd_em_numeros` f,
  UNNEST(f.id_booking) AS booking_id
  WHERE f.dt_reference BETWEEN dt_ini AND dt_fim
    AND f.in_step_scheduling = 1
    AND booking_id IS NOT NULL
    AND LOWER(f.ds_campaign) IN (SELECT campanha FROM campanhas) -- Proteção de processamento mantida
  QUALIFY ROW_NUMBER() OVER (PARTITION BY booking_id ORDER BY f.dt_reference DESC) = 1
),

-- receita: fato tem granularidade de EXAME, somar todos os exames do agendamento
receita AS (
  SELECT
    b.id_navigation_session,
    b.id_agendamento,
    MAX(a.st_agendamento) AS st_agendamento,
    SUM(SAFE_CAST(a.valor_projetado_exame AS NUMERIC)) AS valor_agendado
  FROM bookings b
  INNER JOIN `company-bi-prd.ds_datamart_agendamento.fct_datamart_agendamento` a
    ON b.id_agendamento = a.id_agendamento
  WHERE a.st_agendamento IN ('BOOKED','CANCELLED')
  GROUP BY b.id_navigation_session, b.id_agendamento
),

base AS (
  SELECT
    f.campanha,
    f.source,
    f.id_navigation_session,
    f.step_paciente, f.step_exames, f.step_unidade, f.step_data_hora, f.step_agendou,
    r.id_agendamento, r.st_agendamento, r.valor_agendado
  FROM funil f
  LEFT JOIN receita r ON f.id_navigation_session = r.id_navigation_session
)

SELECT
  campanha,
  ANY_VALUE(source)                                                      AS source,
  COUNT(DISTINCT id_navigation_session)                                  AS sessoes_app_onboarding,
  COUNT(DISTINCT IF(step_paciente  = 1, id_navigation_session, NULL))    AS step_paciente,
  COUNT(DISTINCT IF(step_exames    = 1, id_navigation_session, NULL))    AS step_exames,
  COUNT(DISTINCT IF(step_unidade   = 1, id_navigation_session, NULL))    AS step_unidade,
  COUNT(DISTINCT IF(step_data_hora = 1, id_navigation_session, NULL))    AS step_data_hora,
  COUNT(DISTINCT IF(step_agendou   = 1, id_navigation_session, NULL))    AS sessoes_agendaram,
  COUNT(DISTINCT IF(st_agendamento = 'BOOKED', id_agendamento, NULL))    AS qtd_agendamentos,
  ROUND(SUM(IF(st_agendamento = 'BOOKED', valor_agendado, 0)), 2)        AS receita_agendada
FROM base
GROUP BY campanha
ORDER BY sessoes_app_onboarding DESC
