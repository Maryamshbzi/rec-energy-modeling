-- ==============================================================================
-- ENERGY BALANCE & KPI CALCULATION MODULE
-- Description: Computes Self-Consumption Index (SCI), Self-Sufficiency Index (SSI),
-- Over-Production Index (OPI), Environmental, and Economic Impacts at the
-- primary substation (cabin) and provincial levels for the Sicilia region.
-- ==============================================================================

SET work_mem = '1GB';

-- ------------------------------------------------------------------------------
-- 1. ENVIRONMENT OPTIMIZATION & CALENDAR SETUP
-- ------------------------------------------------------------------------------
-- 2024 Leap Year Calendar Mapping (Working days 'FR' vs Holidays/Weekends 'FS')
DROP TABLE IF EXISTS temp_days_in_month;
CREATE TEMP TABLE temp_days_in_month (month int2, fr_fs varchar(2), days int2);

INSERT INTO temp_days_in_month VALUES
    (1, 'FR', 22), (1, 'FS', 9),
    (2, 'FR', 21), (2, 'FS', 8),
    (3, 'FR', 21), (3, 'FS', 10),
    (4, 'FR', 20), (4, 'FS', 10),
    (5, 'FR', 22), (5, 'FS', 9),
    (6, 'FR', 20), (6, 'FS', 10),
    (7, 'FR', 23), (7, 'FS', 8),
    (8, 'FR', 21), (8, 'FS', 10),
    (9, 'FR', 21), (9, 'FS', 9),
    (10, 'FR', 23), (10, 'FS', 8),
    (11, 'FR', 20), (11, 'FS', 10),
    (12, 'FR', 20), (12, 'FS', 11);

-- ------------------------------------------------------------------------------
-- 2. UNNEST CONSUMPTION ARRAYS TO LONG FORMAT (CABIN LEVEL)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS sicilia.cabin_hourly_demand;
CREATE UNLOGGED TABLE sicilia.cabin_hourly_demand AS
SELECT
    sm.cod_ac,
    sm.cod_prov,
    h.month,
    h.fr_fs,
    hour_idx.hour,
    SUM(hour_idx.total_kwh) AS total_demand_kwh
FROM sicilia.sicilia_building_hourly_consumption h
JOIN sicilia.sicilia_building_spatial_mapping sm 
  ON h.building_fid = sm.building_fid::int8
CROSS JOIN LATERAL (
    SELECT gs.hour, COALESCE(h.total_kwh_arr[gs.hour], 0) AS total_kwh
    FROM generate_series(1, 24) AS gs(hour)
) AS hour_idx
WHERE sm.cod_ac IS NOT NULL
GROUP BY sm.cod_ac, sm.cod_prov, h.month, h.fr_fs, hour_idx.hour;

CREATE INDEX idx_cabin_demand ON sicilia.cabin_hourly_demand (cod_ac, month, fr_fs, hour);
ANALYZE sicilia.cabin_hourly_demand;

-- ------------------------------------------------------------------------------
-- 3. UNNEST PRODUCTION ARRAYS TO LONG FORMAT (CABIN LEVEL)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS sicilia.cabin_hourly_supply;
CREATE UNLOGGED TABLE sicilia.cabin_hourly_supply AS
SELECT
    m.cod_ac,
    m.cod_prov::int4,
    p.month,
    p.fr_fs,
    hour_idx.hour,
    SUM(hour_idx.prod_kwh) AS total_supply_kwh
FROM sicilia.sicilia_actual_plants_hourly_production p
JOIN sicilia.sicilia_actual_plants_spatial_mapping m 
  ON p.plant_fid = m.plant_fid
CROSS JOIN LATERAL (
    SELECT gs.hour, COALESCE(p.production_kwh_arr[gs.hour], 0) AS prod_kwh
    FROM generate_series(1, 24) AS gs(hour)
) AS hour_idx
WHERE m.cod_ac IS NOT NULL
GROUP BY m.cod_ac, m.cod_prov, p.month, p.fr_fs, hour_idx.hour;

CREATE INDEX idx_cabin_supply ON sicilia.cabin_hourly_supply (cod_ac, month, fr_fs, hour);
ANALYZE sicilia.cabin_hourly_supply;

-- ------------------------------------------------------------------------------
-- 4. COMBINE DEMAND & SUPPLY: CALCULATE SC, UD, OP PER HOUR (CABIN LEVEL)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS sicilia.cabin_hourly_balance;
CREATE UNLOGGED TABLE sicilia.cabin_hourly_balance AS
SELECT
    d.cod_ac,
    d.cod_prov,
    d.month,
    d.fr_fs,
    d.hour,
    (d.total_demand_kwh * tm.days) AS tc_kwh,
    (COALESCE(s.total_supply_kwh, 0) * tm.days) AS tp_kwh,
    (LEAST(d.total_demand_kwh, COALESCE(s.total_supply_kwh, 0)) * tm.days) AS sc_kwh,
    (GREATEST(d.total_demand_kwh - COALESCE(s.total_supply_kwh, 0), 0) * tm.days) AS ud_kwh,
    (GREATEST(COALESCE(s.total_supply_kwh, 0) - d.total_demand_kwh, 0) * tm.days) AS op_kwh
FROM sicilia.cabin_hourly_demand d
LEFT JOIN sicilia.cabin_hourly_supply s
    ON  d.cod_ac = s.cod_ac
    AND d.month  = s.month
    AND d.fr_fs  = s.fr_fs
    AND d.hour   = s.hour
LEFT JOIN temp_days_in_month tm
    ON d.month = tm.month AND UPPER(TRIM(d.fr_fs::text)) = tm.fr_fs;

CREATE INDEX idx_cabin_balance ON sicilia.cabin_hourly_balance (cod_ac, month, fr_fs);
ANALYZE sicilia.cabin_hourly_balance;

-- ------------------------------------------------------------------------------
-- 5. ANNUAL SCI & SSI — CABIN LEVEL
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS sicilia.results_cabin;
CREATE TABLE sicilia.results_cabin AS
SELECT
    cod_ac,
    cod_prov,
    ROUND(SUM(tc_kwh)::numeric, 2) AS annual_demand_kwh,
    ROUND(SUM(tp_kwh)::numeric, 2) AS annual_supply_kwh,
    ROUND(SUM(sc_kwh)::numeric, 2) AS annual_sc_kwh,
    ROUND(SUM(ud_kwh)::numeric, 2) AS annual_ud_kwh,
    ROUND(SUM(op_kwh)::numeric, 2) AS annual_op_kwh,
    ROUND(
        CASE WHEN SUM(tp_kwh) > 0 THEN SUM(sc_kwh) / SUM(tp_kwh) ELSE NULL END::numeric, 4
    ) AS sci,
    ROUND(
        CASE WHEN SUM(tc_kwh) > 0 THEN SUM(sc_kwh) / SUM(tc_kwh) ELSE NULL END::numeric, 4
    ) AS ssi
FROM sicilia.cabin_hourly_balance
GROUP BY cod_ac, cod_prov
ORDER BY cod_ac;

CREATE INDEX idx_results_cabin_ac ON sicilia.results_cabin (cod_ac);
CREATE INDEX idx_results_cabin_prov ON sicilia.results_cabin (cod_prov);
ANALYZE sicilia.results_cabin;

-- ------------------------------------------------------------------------------
-- 6. ANNUAL SCI & SSI — PROVINCE LEVEL
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS sicilia.results_province;
CREATE TABLE sicilia.results_province AS
SELECT
    cod_prov,
    ROUND((SUM(tc_kwh) / 1e6)::numeric, 4) AS annual_demand_gwh,
    ROUND((SUM(tp_kwh) / 1e6)::numeric, 4) AS annual_supply_gwh,
    ROUND((SUM(sc_kwh) / 1e6)::numeric, 4) AS annual_sc_gwh,
    ROUND((SUM(ud_kwh) / 1e6)::numeric, 4) AS annual_ud_gwh,
    ROUND((SUM(op_kwh) / 1e6)::numeric, 4) AS annual_op_gwh,
    ROUND(
        CASE WHEN SUM(tp_kwh) > 0 THEN SUM(sc_kwh) / SUM(tp_kwh) ELSE NULL END::numeric, 4
    ) AS sci,
    ROUND(
        CASE WHEN SUM(tc_kwh) > 0 THEN SUM(sc_kwh) / SUM(tc_kwh) ELSE NULL END::numeric, 4
    ) AS ssi
FROM sicilia.cabin_hourly_balance
GROUP BY cod_prov
ORDER BY cod_prov;

ANALYZE sicilia.results_province;

-- ------------------------------------------------------------------------------
-- 7. MONTHLY SCI & SSI — CABIN LEVEL
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS sicilia.results_cabin_monthly;
CREATE TABLE sicilia.results_cabin_monthly AS
SELECT
    cod_ac,
    cod_prov,
    month,
    ROUND(SUM(tc_kwh)::numeric, 2) AS demand_kwh,
    ROUND(SUM(tp_kwh)::numeric, 2) AS supply_kwh,
    ROUND(SUM(sc_kwh)::numeric, 2) AS sc_kwh,
    ROUND(
        CASE WHEN SUM(tp_kwh) > 0 THEN SUM(sc_kwh) / SUM(tp_kwh) ELSE NULL END::numeric, 4
    ) AS sci,
    ROUND(
        CASE WHEN SUM(tc_kwh) > 0 THEN SUM(sc_kwh) / SUM(tc_kwh) ELSE NULL END::numeric, 4
    ) AS ssi
FROM sicilia.cabin_hourly_balance
GROUP BY cod_ac, cod_prov, month
ORDER BY cod_ac, month;

ANALYZE sicilia.results_cabin_monthly;

-- ------------------------------------------------------------------------------
-- 8. QUICK SANITY CHECK
-- ------------------------------------------------------------------------------
-- Regional totals
SELECT
    'SICILIA TOTAL' AS region,
    ROUND(SUM(annual_demand_kwh) / 1e6, 2) AS total_demand_gwh,
    ROUND(SUM(annual_supply_kwh) / 1e6, 2) AS total_supply_gwh,
    ROUND(SUM(annual_sc_kwh) / 1e6, 2)     AS total_sc_gwh,
    ROUND(AVG(sci)::numeric, 4)            AS avg_sci,
    ROUND(AVG(ssi)::numeric, 4)            AS avg_ssi
FROM sicilia.results_cabin;

-- Province summary
SELECT * FROM sicilia.results_province ORDER BY cod_prov;

-- Top 10 cabins by SSI (Most self-sufficient)
SELECT cod_ac, cod_prov, sci, ssi, annual_demand_kwh, annual_supply_kwh
FROM sicilia.results_cabin
WHERE ssi IS NOT NULL
ORDER BY ssi DESC
LIMIT 10;

-- Bottom 10 cabins by SSI (Most dependent on grid)
SELECT cod_ac, cod_prov, sci, ssi, annual_demand_kwh, annual_supply_kwh
FROM sicilia.results_cabin
WHERE ssi IS NOT NULL
ORDER BY ssi ASC
LIMIT 10;

RESET work_mem;

-- ------------------------------------------------------------------------------
-- 9. OPI, GHG EMISSIONS & ECONOMIC VALUE
-- Description: Calculates Over-Production Index (OPI), Avoided CO2, 
-- and Estimated Financial Value.
-- ------------------------------------------------------------------------------
SET work_mem = '1GB';

DROP TABLE IF EXISTS sicilia.advanced_results_cabin;
CREATE TABLE sicilia.advanced_results_cabin AS
SELECT
    cod_ac,
    cod_prov,
    annual_demand_kwh,
    annual_supply_kwh,
    annual_sc_kwh,
    annual_op_kwh,
    sci,
    ssi,
    -- 9.1. OPI: Over-Production Index = OP / Total Production
    ROUND(
        CASE WHEN annual_supply_kwh > 0 
             THEN annual_op_kwh / annual_supply_kwh 
             ELSE NULL 
        END::numeric, 4
    ) AS opi,
    -- 9.2. Environmental Impact: Avoided CO2 eq (Tons) 
    -- Assuming Italy's average grid emission factor of ~0.256 kg CO2eq / kWh
    ROUND(
        (annual_sc_kwh * 0.256 / 1000)::numeric, 2
    ) AS avoided_co2_tons,
    -- 9.3. Economic Feasibility: Estimated Total Benefit (Euros)
    -- Assuming 0.22 €/kWh saved (SC) and 0.10 €/kWh earned/shared (OP)
    ROUND(
        (annual_sc_kwh * 0.22 + annual_op_kwh * 0.10)::numeric, 2
    ) AS economic_benefit_euros
FROM sicilia.results_cabin
ORDER BY cod_ac;

CREATE INDEX idx_adv_results_cabin_ac ON sicilia.advanced_results_cabin(cod_ac);
ANALYZE sicilia.advanced_results_cabin;

-- EXTENDED RESULTS AT PROVINCE LEVEL (Values in GWh and Million Euros)
DROP TABLE IF EXISTS sicilia.advanced_results_province;
CREATE TABLE sicilia.advanced_results_province AS
SELECT
    cod_prov,
    annual_demand_gwh,
    annual_supply_gwh,
    annual_sc_gwh,
    annual_op_gwh,
    sci,
    ssi,
    -- OPI for Province
    ROUND(
        CASE WHEN annual_supply_gwh > 0 
             THEN annual_op_gwh / annual_supply_gwh 
             ELSE NULL 
        END::numeric, 4
    ) AS opi,
    -- Avoided CO2 eq (Kilotons)
    ROUND(
        (annual_sc_gwh * 0.256 * 1000)::numeric, 2
    ) AS avoided_co2_kilo_tons,
    -- Estimated Total Benefit (Million Euros)
    ROUND(
        (annual_sc_gwh * 0.22 * 1000 + annual_op_gwh * 0.10 * 1000)::numeric, 2
    ) AS economic_benefit_million_euros
FROM sicilia.results_province
ORDER BY cod_prov;

ANALYZE sicilia.advanced_results_province;

-- Quick Overview of Advanced KPIs
SELECT 
    'SICILIA TOTAL ADVANCED' AS region,
    ROUND(AVG(opi)::numeric, 4) AS avg_opi,
    SUM(avoided_co2_kilo_tons) AS total_avoided_co2_kilotons,
    SUM(economic_benefit_million_euros) AS total_economic_benefit_million_euros
FROM sicilia.advanced_results_province;

RESET work_mem;

-- ------------------------------------------------------------------------------
-- 10. ENVIRONMENTAL ENGINEERING NEXUS (AIR & WATER)
-- Description: Calculates Avoided Pollutants and Water Savings at Province Level.
-- Replaces the National Grid Mix (Fossil-heavy) with Local RES Mix.
-- ------------------------------------------------------------------------------
SET work_mem = '1GB';

DROP TABLE IF EXISTS sicilia.environmental_nexus_province;
CREATE TABLE sicilia.environmental_nexus_province AS
SELECT
    cod_prov,
    annual_supply_gwh, 
    
    -- 10.1. CLIMATE CHANGE: Avoided CO2 eq (Kilotons) -> ~256 tons CO2 / GWh
    ROUND(
        (annual_supply_gwh * 256 / 1000)::numeric, 2
    ) AS avoided_co2_kilotons,
    
    -- 10.2. AIR QUALITY: Avoided NOx (Tons) -> ~0.4 tons NOx / GWh
    ROUND(
        (annual_supply_gwh * 0.4)::numeric, 2
    ) AS avoided_nox_tons,
    
    -- 10.3. AIR QUALITY: Avoided SO2 (Tons) -> ~0.15 tons SO2 / GWh
    ROUND(
        (annual_supply_gwh * 0.15)::numeric, 2
    ) AS avoided_so2_tons,
    
    -- 10.4. AIR QUALITY: Avoided PM10 (Tons) -> ~0.02 tons PM10 / GWh
    ROUND(
        (annual_supply_gwh * 0.02)::numeric, 2
    ) AS avoided_pm10_tons,
    
    -- 10.5. WATER FOOTPRINT: Water Saved (Cubic Meters) -> ~2500 m3 / GWh
    ROUND(
        (annual_supply_gwh * 2500)::numeric, 0
    ) AS water_saved_cubic_meters
FROM sicilia.results_province
ORDER BY cod_prov;

ANALYZE sicilia.environmental_nexus_province;

-- Quick Overview of Environmental Impact
SELECT 
    'SICILIA TOTAL ENVIRONMENTAL IMPACT' AS region,
    ROUND(SUM(annual_supply_gwh)::numeric, 2) AS total_clean_energy_gwh,
    SUM(avoided_co2_kilotons) AS total_avoided_co2_kilotons,
    SUM(avoided_nox_tons) AS total_avoided_nox_tons,
    SUM(avoided_so2_tons) AS total_avoided_so2_tons,
    SUM(avoided_pm10_tons) AS total_avoided_pm10_tons,
    SUM(water_saved_cubic_meters) AS total_water_saved_m3
FROM sicilia.environmental_nexus_province;

RESET work_mem;