-- ==============================================================================
-- CONSUMPTION MODULE: PUGLIA REGION
-- Description: Spatial mapping, morphological estimation, sectoral downscaling, 
-- and high-resolution hourly disaggregation of building energy demand.
-- Note: Customized for Puglia's regional building typologies (e.g., Trullo).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. ENVIRONMENT INITIALIZATION & INDEXING
-- ------------------------------------------------------------------------------
-- Enable PostGIS spatial extension
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS puglia;

-- Terminate conflicting sessions to prevent locks during heavy spatial joins
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE usename = current_user AND pid <> pg_backend_pid();

-- Optimize memory for complex spatial processing
SET work_mem = '1GB';

-- Create baseline spatial indexes (GIST) for high-performance geometric queries
-- Note: prov_2024 and primarycabins_2025 use "Shape" as the geometry column.
CREATE INDEX IF NOT EXISTS idx_puglia_buildings_geom ON puglia.puglia_buildings USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_prov_geom ON public.prov_2024 USING GIST("Shape");
CREATE INDEX IF NOT EXISTS idx_c11_geom ON puglia.r16_censimento_2011 USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_c21_geom ON puglia.r16_censimento_2021 USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_cab_geom ON public.primarycabins_2025 USING GIST("Shape");

ANALYZE puglia.puglia_buildings;

-- ------------------------------------------------------------------------------
-- 2. SPATIAL MAPPING (TOPOLOGICAL INTEGRATION)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS puglia.puglia_building_spatial_mapping (
    building_fid text PRIMARY KEY,
    year int,
    cod_prov text,
    sez2011 text,
    sez2021 text,
    cod_ac text
);

TRUNCATE TABLE puglia.puglia_building_spatial_mapping;

-- Extract centroids to optimize Point-in-Polygon (PiP) operations
DROP TABLE IF EXISTS temp_building_centroids;
CREATE TEMP TABLE temp_building_centroids AS
SELECT fid, ST_Centroid(geom) AS point_geom
FROM puglia.puglia_buildings;

CREATE INDEX idx_temp_centroids_geom ON temp_building_centroids USING GIST(point_geom);
ANALYZE temp_building_centroids;

-- 2.1 Primary PiP Mapping
INSERT INTO puglia.puglia_building_spatial_mapping (building_fid, year, cod_prov, sez2011, sez2021, cod_ac)
SELECT DISTINCT ON (b.fid)  
    b.fid::text,
    2024,
    p.cod_prov::text,
    c11.sez2011::text,    
    c21.sez21_id::text,   
    cab.cod_ac::text
FROM temp_building_centroids b
LEFT JOIN public.prov_2024 p ON ST_Within(b.point_geom, p."Shape")
LEFT JOIN puglia.r16_censimento_2011 c11 ON ST_Within(b.point_geom, c11.geom)
LEFT JOIN puglia.r16_censimento_2021 c21 ON ST_Within(b.point_geom, c21.geom)
LEFT JOIN public.primarycabins_2025 cab ON ST_Within(b.point_geom, cab."Shape")
ORDER BY b.fid;

-- 2.2 Nearest Neighbor Rescue Logic (for boundary edge cases)
UPDATE puglia.puglia_building_spatial_mapping m
SET 
    cod_prov = COALESCE(m.cod_prov, sub.new_prov),
    sez2011  = COALESCE(m.sez2011, sub.new_sez11),
    sez2021  = COALESCE(m.sez2021, sub.new_sez21),
    cod_ac   = COALESCE(m.cod_ac, sub.new_cab)
FROM (
    SELECT 
        m2.building_fid,
        p_near.cod_prov as new_prov,
        c11_near.sez2011 as new_sez11,
        c21_near.sez21_id as new_sez21,
        cab_near.cod_ac as new_cab
    FROM puglia.puglia_building_spatial_mapping m2
    JOIN temp_building_centroids b ON m2.building_fid = b.fid::text
    LEFT JOIN LATERAL (SELECT cod_prov::text FROM public.prov_2024 ORDER BY b.point_geom <-> "Shape" LIMIT 1) p_near ON TRUE
    LEFT JOIN LATERAL (SELECT sez2011::text FROM puglia.r16_censimento_2011 ORDER BY b.point_geom <-> geom LIMIT 1) c11_near ON TRUE
    LEFT JOIN LATERAL (SELECT sez21_id::text FROM puglia.r16_censimento_2021 ORDER BY b.point_geom <-> geom LIMIT 1) c21_near ON TRUE
    LEFT JOIN LATERAL (SELECT cod_ac::text FROM public.primarycabins_2025 ORDER BY b.point_geom <-> "Shape" LIMIT 1) cab_near ON TRUE
    WHERE m2.cod_prov IS NULL OR m2.sez2011 IS NULL OR m2.sez2021 IS NULL
) AS sub
WHERE m.building_fid = sub.building_fid;

DROP TABLE temp_building_centroids;

-- ------------------------------------------------------------------------------
-- 3. MASTER INTEGRATION & PHYSICAL PARAMETERS ESTIMATION
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS puglia.puglia_buildings_integrated;

-- Consolidate spatial, building, and census data into a single master table
CREATE TABLE puglia.puglia_buildings_integrated AS
SELECT 
    b.*,
    m.cod_prov, m.sez2011, m.sez2021, m.cod_ac,
    i11."E8", i11."E9", i11."E10", i11."E11", i11."E12", 
    i11."E13", i11."E14", i11."E15", i11."E16",
    i11."E17", i11."E18", i11."E19", i11."E20",
    i21."A8" as a8
FROM puglia.puglia_buildings b
JOIN puglia.puglia_building_spatial_mapping m ON b.fid::text = TRIM(m.building_fid)
LEFT JOIN puglia.r16_indicatori_2011_sezioni i11 ON TRIM(m.sez2011) = TRIM(i11."SEZ2011"::text)
LEFT JOIN puglia.r16_indicatori_2021_sezioni i21 ON TRIM(m.sez2021) = TRIM(i21."SEZ21_ID"::text);

ALTER TABLE puglia.puglia_buildings_integrated 
ADD COLUMN construction_year_range text,
ADD COLUMN floors integer,
ADD COLUMN final_height float8,
ADD COLUMN is_energy_relevant boolean;

-- 3.1 Morphological Parameter Derivation (Age & Floor Count)
UPDATE puglia.puglia_buildings_integrated
SET 
    construction_year_range = CASE 
        WHEN COALESCE("E8",0)+COALESCE("E9",0)+COALESCE("E10",0)+COALESCE("E11",0)+COALESCE("E12",0)+COALESCE("E13",0)+COALESCE("E14",0)+COALESCE("E15",0)+COALESCE("E16",0) = 0 THEN NULL
        WHEN COALESCE("E8",0)  = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN 'Before 1919'
        WHEN COALESCE("E9",0)  = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN '1919-1945'
        WHEN COALESCE("E10",0) = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN '1946-1960'
        WHEN COALESCE("E11",0) = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN '1961-1970'
        WHEN COALESCE("E12",0) = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN '1971-1980'
        WHEN COALESCE("E13",0) = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN '1981-1990'
        WHEN COALESCE("E14",0) = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN '1991-2000'
        WHEN COALESCE("E15",0) = GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0),COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN '2001-2005'
        ELSE 'Post-2005' 
    END,
    floors = CASE 
        WHEN COALESCE("E17",0)+COALESCE("E18",0)+COALESCE("E19",0)+COALESCE("E20",0) = 0 THEN 1
        WHEN COALESCE("E20",0) = GREATEST(COALESCE("E17",0),COALESCE("E18",0),COALESCE("E19",0),COALESCE("E20",0)) THEN 4
        WHEN COALESCE("E19",0) = GREATEST(COALESCE("E17",0),COALESCE("E18",0),COALESCE("E19",0),COALESCE("E20",0)) THEN 3
        WHEN COALESCE("E18",0) = GREATEST(COALESCE("E17",0),COALESCE("E18",0),COALESCE("E19",0),COALESCE("E20",0)) THEN 2
        ELSE 1 
    END;

-- 3.2 Final Height Inference
UPDATE puglia.puglia_buildings_integrated
SET final_height = CASE 
    WHEN h >= 2.5 AND h <= 150 THEN h
    WHEN COALESCE("E17",0)+COALESCE("E18",0)+COALESCE("E19",0)+COALESCE("E20",0) = 0 THEN NULL
    ELSE floors * (
        CASE 
            WHEN GREATEST(COALESCE("E8",0),COALESCE("E9",0),COALESCE("E10",0),COALESCE("E11",0)) >= 
                 GREATEST(COALESCE("E12",0),COALESCE("E13",0),COALESCE("E14",0),COALESCE("E15",0),COALESCE("E16",0)) THEN 3.3
            ELSE 3.0
        END
    )
END;

-- ------------------------------------------------------------------------------
-- 4. VOLUMETRIC ALLOCATION & SECTORAL CLASSIFICATION
-- ------------------------------------------------------------------------------
ALTER TABLE puglia.puglia_buildings_integrated 
ADD COLUMN res_piano float8 DEFAULT 0,
ADD COLUMN no_res_piano float8 DEFAULT 0,
ADD COLUMN volume_m3 float8 DEFAULT 0,
ADD COLUMN res_v float8 DEFAULT 0,
ADD COLUMN no_res_v float8 DEFAULT 0,
ADD COLUMN ser_v float8 DEFAULT 0,
ADD COLUMN ind_v float8 DEFAULT 0,
ADD COLUMN agr_v float8 DEFAULT 0;

-- 4.1 Filter energy-relevant structures
UPDATE puglia.puglia_buildings_integrated SET is_energy_relevant = FALSE;

-- Exclude 'Others', ruins ('diroccato'), under construction, shacks, and underground
UPDATE puglia.puglia_buildings_integrated
SET is_energy_relevant = TRUE
WHERE area >= 50 
  AND final_height >= 3.0 
  AND classifica != 'Others'
  AND edifc_uso NOT ILIKE '%diroccato%'
  AND edifc_uso NOT ILIKE '%costruzione%'
  AND edifc_uso NOT ILIKE '%Baracca%'
  AND edifc_uso NOT ILIKE '%interrato%'
  AND floors IS NOT NULL;

-- 4.2 Floor split logic
UPDATE puglia.puglia_buildings_integrated
SET res_piano = floors, no_res_piano = 0
WHERE is_energy_relevant = TRUE 
  AND (classifica IN ('RL', 'RM') OR edifc_uso ILIKE '%Edificio civile%');

UPDATE puglia.puglia_buildings_integrated
SET no_res_piano = floors, res_piano = 0
WHERE is_energy_relevant = TRUE 
  AND (classifica IN ('PA', 'SP', 'TC', 'TH', 'TI', 'TS', 'TT') 
       OR edifc_uso ILIKE ANY (ARRAY['%agricolo%', '%Serra%', '%Trullo%', '%Pagghiara%', '%Cabina%', '%sylos%', '%torre%', '%Capannone%', '%Chiesa%', '%Piscina%', '%castello%', '%sportivo%']));

-- 4.3 Volume Initialization
UPDATE puglia.puglia_buildings_integrated
SET 
    volume_m3 = area * final_height,
    res_v = CASE WHEN is_energy_relevant = TRUE AND floors > 0 THEN (area * final_height) * (res_piano::float / floors) ELSE 0 END,
    no_res_v = CASE WHEN is_energy_relevant = TRUE AND floors > 0 THEN (area * final_height) * (no_res_piano::float / floors) ELSE 0 END;

-- 4.4 Sectoral Assignment (Agriculture, Industry, Services) customized for Puglia
UPDATE puglia.puglia_buildings_integrated
SET 
    agr_v = CASE WHEN is_energy_relevant = TRUE AND (classifica = 'PA' OR edifc_uso ILIKE ANY (ARRAY['%capannone agricolo%', '%Pagghiara%', '%Serra%', '%Trullo%'])) THEN no_res_v ELSE 0 END,
    ind_v = CASE WHEN is_energy_relevant = TRUE AND (classifica = 'SP' OR edifc_uso ILIKE ANY (ARRAY['%Cabina elettrica%', '%Cabina gas%', '%cabina acquedotto%', '%sylos%', '%torre%', '%faro%', '%Capannone%'])) AND edifc_uso NOT ILIKE '%capannone agricolo%' THEN no_res_v ELSE 0 END,
    ser_v = CASE WHEN is_energy_relevant = TRUE AND (classifica IN ('TC', 'TH', 'TI', 'TS', 'TT') OR edifc_uso ILIKE ANY (ARRAY['%Chiesa%', '%campanile%', '%Campo sportivo coperto%', '%Cappella cimiteriale%', '%castello%', '%Piscina%', '%tendone pressurizzato%', '%bastione%', '%casello%'])) THEN no_res_v ELSE 0 END
WHERE is_energy_relevant = TRUE AND no_res_v > 0;

-- Fallback for unclassified structures
UPDATE puglia.puglia_buildings_integrated
SET ser_v = no_res_v
WHERE is_energy_relevant = TRUE AND no_res_v > 0 AND agr_v = 0 AND ind_v = 0 AND ser_v = 0;

-- ------------------------------------------------------------------------------
-- 5. SPATIAL DOWNSCALING: DENOMINATORS & EMPLOYEES
-- ------------------------------------------------------------------------------
ALTER TABLE puglia.puglia_buildings_integrated
ADD COLUMN total_agr_v_sez float8 DEFAULT 0,
ADD COLUMN total_ind_v_sez float8 DEFAULT 0,
ADD COLUMN total_ser_v_sez float8 DEFAULT 0,
ADD COLUMN total_res_v_sez float8 DEFAULT 0,
ADD COLUMN dw_a8_21 float8 DEFAULT 0,
ADD COLUMN ratio_empty_11 float8 DEFAULT 0,
ADD COLUMN active_dwellings_21 float8 DEFAULT 0,
ADD COLUMN work_agr_11 float8 DEFAULT 0,
ADD COLUMN work_ind_11 float8 DEFAULT 0,
ADD COLUMN work_ser_11 float8 DEFAULT 0;

-- 5.1 Volumetric Aggregation to Census Sections (Up-scaling)
WITH summary_2011 AS (
    SELECT sez2011, SUM(COALESCE(agr_v, 0)) AS sum_agr, SUM(COALESCE(ind_v, 0)) AS sum_ind, SUM(COALESCE(ser_v, 0)) AS sum_ser
    FROM puglia.puglia_buildings_integrated WHERE is_energy_relevant = TRUE GROUP BY sez2011
)
UPDATE puglia.r16_indicatori_2011_sezioni AS i
SET total_agr_v_sez = s.sum_agr, total_ind_v_sez = s.sum_ind, total_ser_v_sez = s.sum_ser
FROM summary_2011 AS s WHERE i."SEZ2011"::text = s.sez2011::text;

WITH summary_2021 AS (
    SELECT sez2021, SUM(COALESCE(res_v, 0)) AS sum_res_v
    FROM puglia.puglia_buildings_integrated WHERE is_energy_relevant = TRUE GROUP BY sez2021
)
UPDATE puglia.r16_indicatori_2021_sezioni AS i
SET total_res_v_sez = COALESCE(s.sum_res_v, 0)
FROM summary_2021 AS s WHERE i."SEZ21_ID"::text = s.sez2021::text;

-- 5.2 Transfer Denominators back to Buildings
UPDATE puglia.puglia_buildings_integrated AS b
SET total_agr_v_sez = i.total_agr_v_sez, total_ind_v_sez = i.total_ind_v_sez, total_ser_v_sez = i.total_ser_v_sez
FROM puglia.r16_indicatori_2011_sezioni AS i WHERE b.is_energy_relevant = TRUE AND b.sez2011::text = i."SEZ2011"::text;

UPDATE puglia.puglia_buildings_integrated AS b
SET total_res_v_sez = i.total_res_v_sez
FROM puglia.r16_indicatori_2021_sezioni AS i WHERE b.is_energy_relevant = TRUE AND b.sez2021::text = i."SEZ21_ID"::text;

-- 5.3 Safety Net for Data Imputation (Zero-denominator prevention)
UPDATE puglia.puglia_buildings_integrated
SET 
    total_res_v_sez = CASE WHEN total_res_v_sez = 0 AND res_v > 0 THEN res_v ELSE total_res_v_sez END,
    total_ser_v_sez = CASE WHEN total_ser_v_sez = 0 AND ser_v > 0 THEN ser_v ELSE total_ser_v_sez END,
    total_ind_v_sez = CASE WHEN total_ind_v_sez = 0 AND ind_v > 0 THEN ind_v ELSE total_ind_v_sez END,
    total_agr_v_sez = CASE WHEN total_agr_v_sez = 0 AND agr_v > 0 THEN agr_v ELSE total_agr_v_sez END
WHERE is_energy_relevant = TRUE;

-- 5.4 Downscaling Census Data (Dwellings)
UPDATE puglia.r16_indicatori_2011_sezioni
SET ratio_empty_11 = CASE WHEN (COALESCE("A2",0) + COALESCE("A3",0)) > 0 THEN CAST("A6" AS FLOAT) / ("A2" + "A3") ELSE 0 END;

UPDATE puglia.puglia_buildings_integrated AS b
SET ratio_empty_11 = COALESCE(i11.ratio_empty_11, 0)
FROM puglia.r16_indicatori_2011_sezioni AS i11 WHERE b.sez2011::text = i11."SEZ2011"::text AND b.is_energy_relevant = TRUE;

UPDATE puglia.puglia_buildings_integrated AS b
SET
    dw_a8_21 = CASE WHEN b.total_res_v_sez > 0 THEN (b.res_v / b.total_res_v_sez) * COALESCE(i21."A8"::float, 0) ELSE 0 END,
    active_dwellings_21 = CASE WHEN b.total_res_v_sez > 0 THEN ((b.res_v / b.total_res_v_sez) * COALESCE(i21."A8"::float, 0)) * (1 - b.ratio_empty_11) ELSE 0 END
FROM puglia.r16_indicatori_2021_sezioni AS i21 WHERE b.sez2021::text = i21."SEZ21_ID"::text AND b.is_energy_relevant = TRUE;

-- 5.5 Downscaling Economic Data (Employees based on ATECO)
ALTER TABLE puglia.r16_indicatori_2011_sezioni ADD COLUMN addetti_agri float8 DEFAULT 0, ADD COLUMN addetti_indu float8 DEFAULT 0, ADD COLUMN addetti_serv float8 DEFAULT 0;
ALTER TABLE puglia."16_attecon_sce_2011" ADD COLUMN settore_descrizione TEXT;

UPDATE puglia."16_attecon_sce_2011"
SET settore_descrizione = CASE
    WHEN LEFT(LPAD("ATECO3"::text, 3, '0'), 2)::int BETWEEN 1 AND 3 THEN 'Agricoltura'
    WHEN LEFT(LPAD("ATECO3"::text, 3, '0'), 2)::int BETWEEN 5 AND 43 THEN 'Industria'
    WHEN LEFT(LPAD("ATECO3"::text, 3, '0'), 2)::int BETWEEN 45 AND 99 THEN 'Servizi'
    ELSE 'Non_Classificato'
END;

WITH agg_eco AS (
    SELECT "PROCOM", "NSEZ",
        SUM(CASE WHEN settore_descrizione = 'Agricoltura' THEN COALESCE("ADDETTI", 0) ELSE 0 END) as s_agri,
        SUM(CASE WHEN settore_descrizione = 'Industria' THEN COALESCE("ADDETTI", 0) ELSE 0 END) as s_indu,
        SUM(CASE WHEN settore_descrizione = 'Servizi' THEN COALESCE("ADDETTI", 0) ELSE 0 END) as s_serv
    FROM puglia."16_attecon_sce_2011" GROUP BY "PROCOM", "NSEZ"
)
UPDATE puglia.r16_indicatori_2011_sezioni AS i
SET addetti_agri = a.s_agri, addetti_indu = a.s_indu, addetti_serv = a.s_serv
FROM agg_eco AS a WHERE i."PROCOM"::int = a."PROCOM"::int AND i."NSEZ"::text = a."NSEZ"::text;

UPDATE puglia.puglia_buildings_integrated AS b
SET
    work_agr_11 = CASE WHEN b.total_agr_v_sez > 0 THEN (b.agr_v / b.total_agr_v_sez) * COALESCE(i11.addetti_agri, 0) ELSE 0 END,
    work_ind_11 = CASE WHEN b.total_ind_v_sez > 0 THEN (b.ind_v / b.total_ind_v_sez) * COALESCE(i11.addetti_indu, 0) ELSE 0 END,
    work_ser_11 = CASE WHEN b.total_ser_v_sez > 0 THEN (b.ser_v / b.total_ser_v_sez) * COALESCE(i11.addetti_serv, 0) ELSE 0 END
FROM puglia.r16_indicatori_2011_sezioni AS i11 WHERE b.sez2011::text = i11."SEZ2011"::text AND b.is_energy_relevant = TRUE;

-- ------------------------------------------------------------------------------
-- 6. ANNUAL ENERGY CONSUMPTION MODELING (kWh/year)
-- ------------------------------------------------------------------------------
ALTER TABLE puglia.puglia_buildings_integrated
ADD COLUMN cons_res_kwh_yr float8 DEFAULT 0, ADD COLUMN cons_agr_kwh_yr float8 DEFAULT 0,
ADD COLUMN cons_ind_kwh_yr float8 DEFAULT 0, ADD COLUMN cons_ser_kwh_yr float8 DEFAULT 0;

-- Residential (ARERA Data)
UPDATE puglia.puglia_buildings_integrated AS b
SET cons_res_kwh_yr = b.active_dwellings_21 * COALESCE(a.yearly_kwh, 0)
FROM puglia.puglia_building_spatial_mapping AS m
JOIN puglia.prelievo_medio_dei_clienti_domestici AS a ON CAST(m.cod_prov AS int8) = CAST(a.code_prov AS int8)
WHERE b.fid::text = m.building_fid::text AND a.year = 2024 AND b.is_energy_relevant = TRUE;

-- Service Sector (Residual Method from ENEA - Puglia cod_reg = 16)
WITH regional_metrics AS (
    SELECT "civile_GWh" * 1000000.0 AS total_civil_kwh FROM puglia.rapporto_annuale_sull_efficienza_energetica WHERE report_year = 2025 AND cod_reg = 16 LIMIT 1
),
assigned_totals AS (
    SELECT SUM(COALESCE(cons_res_kwh_yr, 0)) AS total_res_assigned, SUM(COALESCE(work_ser_11, 0)) AS total_emp_relevant
    FROM puglia.puglia_buildings_integrated WHERE is_energy_relevant = TRUE
),
factor_calc AS (
    SELECT (rm.total_civil_kwh - att.total_res_assigned) / NULLIF(att.total_emp_relevant, 0) AS kwh_per_emp
    FROM regional_metrics rm, assigned_totals att
)
UPDATE puglia.puglia_buildings_integrated AS b
SET cons_ser_kwh_yr = COALESCE(b.work_ser_11, 0) * fc.kwh_per_emp
FROM factor_calc fc WHERE b.is_energy_relevant = TRUE;

-- Industry & Agriculture (Proportional Downscaling)
WITH regional_source AS (
    SELECT "industria_GWh" AS total_ind_gwh, "agricoltura e pesca_GWh" AS total_agr_gwh 
    FROM puglia.rapporto_annuale_sull_efficienza_energetica WHERE report_year = 2025 AND cod_reg = 16 LIMIT 1
),
global_drivers AS (
    SELECT SUM(COALESCE(work_ind_11, 0)) AS sum_ind, SUM(COALESCE(work_agr_11, 0)) AS sum_agr
    FROM puglia.puglia_buildings_integrated WHERE is_energy_relevant = TRUE 
)
UPDATE puglia.puglia_buildings_integrated AS b
SET
    cons_ind_kwh_yr = CASE WHEN gd.sum_ind > 0 THEN (b.work_ind_11 / gd.sum_ind) * src.total_ind_gwh * 1000000.0 ELSE 0 END,
    cons_agr_kwh_yr = CASE WHEN gd.sum_agr > 0 THEN (b.work_agr_11 / gd.sum_agr) * src.total_agr_gwh * 1000000.0 ELSE 0 END
FROM regional_source src, global_drivers gd WHERE b.is_energy_relevant = TRUE;

-- ------------------------------------------------------------------------------
-- 7. TEMPORAL DISAGGREGATION (HOURLY ARRAYS)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS puglia.puglia_building_hourly_consumption;

CREATE TABLE puglia.puglia_building_hourly_consumption (
    id SERIAL PRIMARY KEY,
    building_fid int8,
    year int2,
    month int2,
    fr_fs char(2),
    res_kwh_arr real[], 
    ind_kwh_arr real[],
    ser_kwh_arr real[],
    agr_kwh_arr real[],
    total_kwh_arr real[]
);

-- Optimization for array generation
SET work_mem = '1GB'; 

DO $$
DECLARE m integer;
BEGIN
    FOR m IN 1..12 LOOP
        RAISE NOTICE 'Starting processing for Month: %', m;

        CREATE TEMP TABLE temp_monthly_lookup AS
        SELECT
            cod_prov::text as cod_prov, hour, fr_fs,
            MAX(CASE WHEN sector = 'res' THEN coefficient ELSE 0 END)::real as res_coeff,
            MAX(CASE WHEN sector = 'ind' THEN coefficient ELSE 0 END)::real as ind_coeff,
            MAX(CASE WHEN sector = 'ser' THEN coefficient ELSE 0 END)::real as ser_coeff,
            MAX(CASE WHEN sector = 'agr' THEN coefficient ELSE 0 END)::real as agr_coeff
        FROM puglia.puglia_consumption_hourly_profile_lookup 
        WHERE month::integer = m
        GROUP BY cod_prov, hour, fr_fs;

        CREATE INDEX idx_temp_m_fast ON temp_monthly_lookup(cod_prov, hour, fr_fs);

        INSERT INTO puglia.puglia_building_hourly_consumption 
        (building_fid, year, month, fr_fs, res_kwh_arr, ind_kwh_arr, ser_kwh_arr, agr_kwh_arr, total_kwh_arr)
        SELECT
            fid, 2024, m, fr_fs,
            array_agg(r_k ORDER BY hour),
            array_agg(i_k ORDER BY hour),
            array_agg(s_k ORDER BY hour),
            array_agg(a_k ORDER BY hour),
            array_agg((r_k + i_k + s_k + a_k) ORDER BY hour)
        FROM (
            SELECT
                b.fid, p.hour, p.fr_fs,
                (COALESCE(b.cons_res_kwh_yr, 0) * p.res_coeff) AS r_k,
                (COALESCE(b.cons_ind_kwh_yr, 0) * p.ind_coeff) AS i_k,
                (COALESCE(b.cons_ser_kwh_yr, 0) * p.ser_coeff) AS s_k,
                (COALESCE(b.cons_agr_kwh_yr, 0) * p.agr_coeff) AS a_k
            FROM puglia.puglia_buildings_integrated b
            JOIN puglia.puglia_building_spatial_mapping sm ON b.fid::text = sm.building_fid::text
            JOIN temp_monthly_lookup p ON sm.cod_prov::text = p.cod_prov::text
            WHERE b.is_energy_relevant = true
              AND (COALESCE(b.cons_res_kwh_yr, 0) + COALESCE(b.cons_ind_kwh_yr, 0) + 
                   COALESCE(b.cons_ser_kwh_yr, 0) + COALESCE(b.cons_agr_kwh_yr, 0)) > 0
        ) sub
        GROUP BY fid, fr_fs;

        DROP TABLE temp_monthly_lookup;
    END LOOP;
END $$;

-- ------------------------------------------------------------------------------
-- 8. FINAL INDEXING
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_pug_hourly_fid_final ON puglia.puglia_building_hourly_consumption(building_fid);
ANALYZE puglia.puglia_building_hourly_consumption;