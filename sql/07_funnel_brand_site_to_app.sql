-- Funil das campanhas pagas Marca D que levam para /agendamento
-- Site monomarca -> onboarding APP -> etapas do funil -> agendou -> receita
DECLARE dt_ini DATE DEFAULT '2026-07-01';
DECLARE dt_fim DATE DEFAULT '2026-07-20';
WITH campanhas AS (
SELECT *
FROM UNNEST([
   'g006_marca_d_google_pmax_atendimento-domiciliar_conversao_lp',
   'g002_marca_d_google_pmax_agendamento_conversao_lp',
   'g006_marca_d_google_search_coleta-domiciliar_conversao_lp',
   'g004_marca_d_google_search_vacinas_gerais_conversao_lp',
   'g002_marca_d_google_search_agendamento_conversao_lp',
   'f006_marca_d_facebook_multiplos_domiciliar_conversao_lp',
   'f004_marca_d_facebook_multiplos_vacinas_conversao_lp',
   'f002_marca_d_facebook_multiplos_agendamento_conversao_lp'
 ]) AS campanha
),
-- 1 linha por sessao de site (a base tem fan-out de ~7,7 linhas/sessao)
sessoes AS (
SELECT
   LOWER(u.campaign_monomarca)                       AS campanha,
   ANY_VALUE(u.source_monomarca)                     AS source,
   u.sessionid_monomarca,
   ANY_VALUE(u.sessionid_app)                        AS sessionid_app,
   MIN(u.data)                                       AS data,
   ANY_VALUE(u.device_category)                      AS dispositivo
FROM `analytics-project.ds_datamart_dataform_monomarca.tb_dm_ga_unificado_monomarca_app_home_deslogada` u
WHERE u.data BETWEEN dt_ini AND dt_fim
   AND u.marca = 'Marca D'
   AND LOWER(u.campaign_monomarca) IN (SELECT campanha FROM campanhas)
   AND u.sessionid_monomarca IS NOT NULL
GROUP BY campanha, u.sessionid_monomarca
),
-- etapas do funil de agendamento, 1 linha por sessao APP
funil AS (
SELECT
   id_navigation_session,
   MAX(in_step_patient)    AS step_paciente,
   MAX(in_step_exams)      AS step_exames,
   MAX(in_step_unit)       AS step_unidade,
   MAX(in_step_date_hour)  AS step_data_hora,
   MAX(in_step_scheduling) AS step_agendou
FROM `analytics-project.ds_datamart_dataform_app_pacientes.tb_dm_ga_app_pac_funil_agd_em_numeros`
WHERE dt_reference BETWEEN dt_ini AND dt_fim
GROUP BY id_navigation_session
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
   s.campanha,
   s.source,
   s.sessionid_monomarca,
   s.sessionid_app,
   f.step_paciente, f.step_exames, f.step_unidade, f.step_data_hora, f.step_agendou,
   r.id_agendamento, r.st_agendamento, r.valor_agendado
FROM sessoes s
LEFT JOIN funil f  ON s.sessionid_app = f.id_navigation_session
LEFT JOIN receita r ON s.sessionid_app = r.id_navigation_session
)
SELECT
 campanha,
 ANY_VALUE(source)                                                    AS source,
COUNT(DISTINCT sessionid_monomarca)                                  AS sessoes_site,
COUNT(DISTINCT sessionid_app)                                        AS sessoes_app_onboarding,
COUNT(DISTINCT IF(step_paciente  = 1, sessionid_app, NULL))          AS step_paciente,
COUNT(DISTINCT IF(step_exames    = 1, sessionid_app, NULL))          AS step_exames,
COUNT(DISTINCT IF(step_unidade   = 1, sessionid_app, NULL))          AS step_unidade,
COUNT(DISTINCT IF(step_data_hora = 1, sessionid_app, NULL))          AS step_data_hora,
COUNT(DISTINCT IF(step_agendou   = 1, sessionid_app, NULL))          AS sessoes_agendaram,
COUNT(DISTINCT IF(st_agendamento = 'BOOKED', id_agendamento, NULL))  AS qtd_agendamentos,
 ROUND(SUM(IF(st_agendamento = 'BOOKED', valor_agendado, 0)), 2)      AS receita_agendada,
 ROUND(SAFE_DIVIDE(COUNT(DISTINCT sessionid_app),
                   COUNT(DISTINCT sessionid_monomarca)) * 100, 2)     AS pct_site_para_app,
 ROUND(SAFE_DIVIDE(COUNT(DISTINCT IF(step_agendou = 1, sessionid_app, NULL)),
                   COUNT(DISTINCT sessionid_monomarca)) * 100, 2)     AS cvr_geral_pct
FROM base
GROUP BY campanha
ORDER BY sessoes_site DESC