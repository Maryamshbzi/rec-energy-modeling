-- ==============================================================================
-- SUPPLY MODULE: CALABRIA REGION
-- Description: Spatial mapping, annual yield calculation, and hourly
-- temporal disaggregation for renewable energy assets in Calabria.
-- Note: Includes CRS transformation (EPSG:32632) for spatial operations.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. ENVIRONMENT OPTIMIZATION
-- ------------------------------------------------------------------------------
-- Terminate conflicting sessions to prevent locks during heavy spatial joins
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity
WHERE usename = current_user AND pid <> pg_backend_pid();

-- Increase working memory for complex spatial processing and array aggregations
SET work_mem = '1GB';

-- ------------------------------------------------------------------------------
-- 2. SPATIAL INITIALIZATION & MAPPING
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS calabria.calabria_actual_plants_spatial_mapping (
    plant_fid int8 PRIMARY KEY,
    cod_prov int4,
    cod_ac text
);

TRUNCATE TABLE calabria.calabria_actual_plants_spatial_mapping;

-- 2.1. Primary Spatial Join (Point-in-Polygon)
-- Note: Boundaries are dynamically transformed to UTM Zone 32N (EPSG:32632) to match plant geometries.
INSERT INTO calabria.calabria_actual_plants_spatial_mapping (plant_fid, cod_prov, cod_ac)
SELECT 
    a.fid, 
    p.cod_prov::int4,
    c.cod_ac
FROM calabria.calabria_actual_plants a
LEFT JOIN public.prov_2024 p 
    ON ST_Within(a.geom, ST_Transform(p.geom, 32632))
LEFT JOIN public.primarycabins_2025 c 
    ON ST_Within(a.geom, ST_Transform(c.geom, 32632));

-- 2.2. Topological Rescue Logic (Nearest Neighbor Assignment)
-- Assigns orphaned plants to the nearest provincial/cabin boundary.
UPDATE calabria.calabria_actual_plants_spatial_mapping m
SET 
    cod_prov = COALESCE(m.cod_prov, sub.nearest_prov),
    cod_ac = COALESCE(m.cod_ac, sub.nearest_cabin)
FROM (
    SELECT 
        a.fid,
        (SELECT p.cod_prov FROM public.prov_2024 p ORDER BY a.geom <-> p.geom LIMIT 1) AS nearest_prov,
        (SELECT c.cod_ac FROM public.primarycabins_2025 c ORDER BY a.geom <-> c.geom LIMIT 1) AS nearest_cabin
    FROM calabria.calabria_actual_plants a
    JOIN calabria.calabria_actual_plants_spatial_mapping m_check ON a.fid = m_check.plant_fid
    WHERE m_check.cod_prov IS NULL OR m_check.cod_ac IS NULL
) sub
WHERE m.plant_fid = sub.fid;

ANALYZE calabria.calabria_actual_plants_spatial_mapping;

-- ------------------------------------------------------------------------------
-- 3. ANNUAL PRODUCTION CALCULATION
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS calabria.calabria_actual_plants_annual_production (
    plant_fid int8 PRIMARY KEY,
    type_res text,
    cod_prov int4,
    potenza_kw float4,
    yearly_production_kwh float8
);

TRUNCATE TABLE calabria.calabria_actual_plants_annual_production;

-- 3.1. Yield Estimation based on Provincial Capacity Factors (Utilization Hours)
INSERT INTO calabria.calabria_actual_plants_annual_production
SELECT 
    a.fid,
    CASE 
        WHEN UPPER(a.ai_fonte) = 'SOLARE' THEN 'solar'
        WHEN UPPER(a.ai_fonte) = 'EOLICA' THEN 'wind'
        WHEN UPPER(a.ai_fonte) = 'IDRAULICA' THEN 'hydroelectricity'
        WHEN UPPER(a.ai_fonte) IN ('BIOGAS', 'BIOMASSE LIQUIDE', 'BIOMASSE SOLIDE', 'RIFIUTI') THEN 'biomass'
        WHEN UPPER(a.ai_fonte) = 'GEOTERMICA' THEN 'geothermal'
        ELSE 'other'
    END AS type_res,
    m.cod_prov,
    a.potenza::NUMERIC, -- Cast capacity to NUMERIC to maintain precision during aggregation
    CASE 
        WHEN UPPER(a.ai_fonte) = 'SOLARE' THEN a.potenza::NUMERIC * COALESCE(u.solar, 0)
        WHEN UPPER(a.ai_fonte) = 'EOLICA' THEN a.potenza::NUMERIC * COALESCE(u.wind, 0)
        WHEN UPPER(a.ai_fonte) = 'IDRAULICA' THEN a.potenza::NUMERIC * COALESCE(u.hydroelectry, 0)
        WHEN UPPER(a.ai_fonte) IN ('BIOGAS', 'BIOMASSE LIQUIDE', 'BIOMASSE SOLIDE', 'RIFIUTI') THEN a.potenza::NUMERIC * COALESCE(u.biomass, 0)
        WHEN UPPER(a.ai_fonte) = 'GEOTERMICA' THEN a.potenza::NUMERIC * COALESCE(u.geothermal, 0)
        ELSE 0 
    END AS yearly_production_kwh
FROM calabria.calabria_actual_plants a
JOIN calabria.calabria_actual_plants_spatial_mapping m ON a.fid = m.plant_fid
JOIN calabria.calabria_actual_plants_utilization_hour u ON m.cod_prov = u.cod_prov;

-- ------------------------------------------------------------------------------
-- 4. HOURLY PRODUCTION DISAGGREGATION (ARRAY-BASED)
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_calabria_plants_geom ON calabria.calabria_actual_plants USING gist(geom);

UPDATE calabria.calabria_actual_production_hourly_profile_lookup SET type_res = TRIM(LOWER(type_res));
UPDATE calabria.calabria_actual_plants_annual_production SET type_res = TRIM(LOWER(type_res));

-- 4.1. Initialize Output Table
DROP TABLE IF EXISTS calabria.calabria_actual_plants_hourly_production;
CREATE UNLOGGED TABLE calabria.calabria_actual_plants_hourly_production (
    plant_fid int8,
    month int2,
    fr_fs char(2),
    type_res text,
    production_kwh_arr real[] 
);

-- 4.2. Monthly Iteration for High-Performance Array Aggregation
DO $$
DECLARE
    m integer;
BEGIN
    FOR m IN 1..12 LOOP
        RAISE NOTICE 'Processing supply temporal profiles for month: %', m;

        -- Localized temporary lookup to minimize memory overhead
        CREATE TEMP TABLE temp_prod_lookup AS
        SELECT 
            cod_prov::text as cod_prov, 
            type_res, 
            fr_fs, 
            hour, 
            coefficient::real
        FROM calabria.calabria_actual_production_hourly_profile_lookup
        WHERE month::integer = m;

        CREATE INDEX idx_temp_prod ON temp_prod_lookup(cod_prov, type_res, fr_fs);

        -- Distribute annual yield into 24-hour arrays via Cartesian cross-multiplication
        INSERT INTO calabria.calabria_actual_plants_hourly_production
        SELECT 
            sub.plant_fid,
            m,
            sub.fr_fs,
            sub.type_res,
            array_agg(sub.p_k ORDER BY sub.hour) as production_kwh_arr
        FROM (
            SELECT 
                s.plant_fid,
                l.fr_fs,
                l.hour,
                s.type_res,
                (COALESCE(s.yearly_production_kwh, 0) * l.coefficient)::real AS p_k
            FROM calabria.calabria_actual_plants_annual_production s
            JOIN temp_prod_lookup l 
              ON s.cod_prov::text = l.cod_prov::text 
              AND s.type_res = l.type_res 
        ) sub
        GROUP BY sub.plant_fid, sub.fr_fs, sub.type_res;

        DROP TABLE temp_prod_lookup;
    END LOOP;
END $$;

-- ------------------------------------------------------------------------------
-- 5. FINALIZATION & INDEXING
-- ------------------------------------------------------------------------------
-- Convert to permanent logged table and index for spatial queries
ALTER TABLE calabria.calabria_actual_plants_hourly_production SET LOGGED;

CREATE INDEX IF NOT EXISTS idx_plant_final_fid ON calabria.calabria_actual_plants_hourly_production (plant_fid);

ANALYZE calabria.calabria_actual_plants_hourly_production;