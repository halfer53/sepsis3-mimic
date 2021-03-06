-- ------------------------------------------------------------------
-- Title: Logistic organ dysfunction system (LODS)
-- MIMIC version: MIMIC-III v1.4
-- Originally written by: Alistair Johnson
-- Contact: aewj [at] mit [dot] edu
-- ------------------------------------------------------------------

-- This query extracts the logistic organ dysfunction system.
-- This score is a measure of organ failure in a patient.
-- The score is calculated across the *entire* ICU patients' stay.
-- The score is calculated for *all* ICU patients, with the assumption that the user will subselect appropriate ICUSTAY_IDs.
-- For example, the score is calculated for neonates, but it is likely inappropriate to actually use the score values for these patients.

-- Reference for LODS:
--  Le Gall, J. R., Klar, J., Lemeshow, S., Saulnier, F., Alberti, C., Artigas, A., & Teres, D.
--  The Logistic Organ Dysfunction system: a new way to assess organ dysfunction in the intensive care unit.
--  JAMA 276.10 (1996): 802-810.

-- Variables used in LODS:
--  GCS
--  VITALS: Heart rate, systolic blood pressure
--  FLAGS: ventilation/cpap
--  IO: urine output
--  LABS: blood urea nitrogen, WBC, bilirubin, creatinine, INR, platelets
--  ABG: PaO2 with associated FiO2

DROP MATERIALIZED VIEW IF EXISTS LODS_si;
CREATE MATERIALIZED VIEW LODS_si as
-- extract CPAP from the "Oxygen Delivery Device" fields
with cpap as
(
  select ie.icustay_id
    , min(charttime - interval '1' hour) as starttime
    , max(charttime + interval '4' hour) as endtime
    , max(case when lower(value) similar to '%(cpap mask|bipap mask)%' then 1 else 0 end) as cpap
  from icustays ie
  inner join chartevents ce
    on ie.icustay_id = ce.icustay_id
    and ce.charttime between ie.intime and ie.outtime
  where itemid in
  (
    -- TODO: when metavision data import fixed, check the values in 226732 match the value clause below
    467, 469, 226732
  )
  and lower(value) similar to '%(cpap mask|bipap mask)%'
  -- exclude rows marked as error
  AND ce.error IS DISTINCT FROM 1
  group by ie.icustay_id
)
, pafi1 as
(
  -- join blood gas to ventilation durations to determine if patient was vent
  -- also join to cpap table for the same purpose
  select bg.icustay_id, bg.charttime
  , PaO2FiO2
  , case when vd.icustay_id is not null then 1 else 0 end as vent
  , case when cp.icustay_id is not null then 1 else 0 end as cpap
  from bloodgasarterial_si bg
  left join ventdurations vd
    on bg.icustay_id = vd.icustay_id
    and bg.charttime >= vd.starttime
    and bg.charttime <= vd.endtime
  left join cpap cp
    on bg.icustay_id = cp.icustay_id
    and bg.charttime >= cp.starttime
    and bg.charttime <= cp.endtime
)
, pafi2 as
(
  -- get the minimum PaO2/FiO2 ratio *only for ventilated/cpap patients*
  select icustay_id
  , min(PaO2FiO2) as PaO2FiO2_vent_min
  from pafi1
  where vent = 1 or cpap = 1
  group by icustay_id
)
, cohort as
(
select  ie.subject_id
      , ie.hadm_id
      , ie.icustay_id
      , ie.intime
      , ie.outtime

      , gcs.mingcs
      , vital.heartrate_max
      , vital.heartrate_min
      , vital.sysbp_max
      , vital.sysbp_min

      -- this value is non-null iff the patient is on vent/cpap
      , pf.PaO2FiO2_vent_min

      , labs.bun_max
      , labs.bun_min
      , labs.wbc_max
      , labs.wbc_min
      , labs.bilirubin_max
      , labs.creatinine_max
      , labs.inr_max
      , labs.platelet_min

      , uo.urineoutput

from suspinfect_poe s
inner join icustays ie
  on s.icustay_id = ie.icustay_id
inner join admissions adm
  on ie.hadm_id = adm.hadm_id
inner join patients pat
  on ie.subject_id = pat.subject_id

-- join to above view to get pao2/fio2 ratio
left join pafi2 pf
  on ie.icustay_id = pf.icustay_id

-- join to custom tables to get more data....
left join gcs_si gcs
  on ie.icustay_id = gcs.icustay_id
left join vitals_si vital
  on ie.icustay_id = vital.icustay_id
left join uo_si uo
  on ie.icustay_id = uo.icustay_id
left join labs_si labs
  on ie.icustay_id = labs.icustay_id
)
, scorecomp as
(
select
  cohort.*
  -- Below code calculates the component scores needed for SAPS

  -- neurologic
  , case
    when mingcs is null then null
      when mingcs <  3 then null -- erroneous value/on trach
      when mingcs <=  5 then 5
      when mingcs <=  8 then 3
      when mingcs <= 13 then 1
    else 0
  end as neurologic

  -- cardiovascular
  , case
      when heartrate_max is null
      and sysbp_min is null then null
      when heartrate_min < 30 then 5
      when sysbp_min < 40 then 5
      when sysbp_min <  70 then 3
      when sysbp_max >= 270 then 3
      when heartrate_max >= 140 then 1
      when sysbp_max >= 240 then 1
      when sysbp_min < 90 then 1
    else 0
  end as cardiovascular

  -- renal
  , case
      when bun_max is null
        or UrineOutput is null
        or creatinine_max is null
        then null
      when UrineOutput <   500.0 then 5
      when bun_max >= 56.0 then 5
      when creatinine_max >= 1.60 then 3
      when UrineOutput <   750.0 then 3
      when bun_max >= 28.0 then 3
      when UrineOutput >= 10000.0 then 3
      when creatinine_max >= 1.20 then 1
      when bun_max >= 17.0 then 1
      when bun_max >= 7.50 then 1
    else 0
  end as renal

  -- pulmonary
  , case
      when PaO2FiO2_vent_min is null then 0
      when PaO2FiO2_vent_min >= 150 then 1
      when PaO2FiO2_vent_min < 150 then 3
    else null
  end as pulmonary

  -- hematologic
  , case
      when wbc_max is null
        and platelet_min is null
          then null
      when wbc_min <   1.0 then 3
      when wbc_min <   2.5 then 1
      when platelet_min < 1.0 then 1
      when wbc_max >= 50.0 then 1
    else 0
  end as hematologic

  -- hepatic
  , case
      when inr_max is null
        and bilirubin_max is null
          then null
      when bilirubin_max >= 2.0 then 1
      when inr_max >= 1.25 then 1
    else 0
  end as hepatic

from cohort
)
select si.icustay_id
-- coalesce statements impute normal score of zero if data element is missing
, coalesce(neurologic,0)
+ coalesce(cardiovascular,0)
+ coalesce(renal,0)
+ coalesce(pulmonary,0)
+ coalesce(hematologic,0)
+ coalesce(hepatic,0)
  as LODS
, neurologic
, cardiovascular
, renal
, pulmonary
, hematologic
, hepatic
from suspinfect_poe si
left join scorecomp s
  on si.icustay_id = s.icustay_id
where si.suspected_infection_time is not null
order by si.icustay_id;
