"""
===========================================================================
TEMPORAL DISAGGREGATION PROFILE BUILDER
===========================================================================
Description: 
This algorithm ingests raw regional load profiles, normalizes hourly 
coefficients against the annual integral (accounting for the 2024 calendar 
working/festive days), and reshapes the matrix into a relational database 
format (Long format) for PostgreSQL injection.
===========================================================================
"""

import os
import glob
import pandas as pd
import numpy as np

# ===========================================================================
# 1. METADATA & CALENDAR CONFIGURATION
# ===========================================================================
REGION = 'sicilia'  # Change this to 'puglia' or 'calabria' for other regions
INPUT_FOLDER = f'{REGION}/'
OUTPUT_FILENAME_WIDE = f'{REGION}_prov_hourly_profile_wide.csv'
OUTPUT_FILENAME_LONG = f'{REGION}_consumption_hourly_profile_lookup.csv'

# Provincial mapping codes (Aligned with ISTAT COD_PROV standards)
# Update this dictionary when switching to a different region!
PROV_ID_MAP = {
    'Trapani': 81, 'Palermo': 82, 'Messina': 83, 'Agrigento': 84,
    'Caltanissetta': 85, 'Enna': 86, 'Catania': 87, 'Ragusa': 88, 'Siracusa': 89
}

PROVINCES_LIST = [{'prov_code': code, 'name': name} for name, code in PROV_ID_MAP.items()]

# 2024 Calendar Configuration: Working days (FR) and Festive/Weekend days (FS)
# Format: 'month': [FR_days, FS_days]
DAYS_DATA = {
    'gen': [19, 12], 'feb': [20, 8], 'mar': [19, 12], 'apr': [17, 13],
    'mag': [20, 11], 'giu': [19, 11], 'lug': [23, 8], 'ago': [11, 20],
    'set': [21, 9],  'ott': [23, 8],  'nov': [20, 10], 'dic': [14, 17]
}

WINTER_MONTHS = ['nov', 'dic', 'gen', 'feb', 'mar', 'apr']
SUMMER_MONTHS = ['mag', 'giu', 'lug', 'ago', 'set', 'ott']
MONTHS_ORDER = ['gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic']
DAY_TYPES = ['fr', 'fs']
HOURS = range(1, 25)

# Initialize Wide Format Data Structure
ORDERED_COLS_BASE = [f"{m}_{dt}_hour{h}" for m in MONTHS_ORDER for dt in DAY_TYPES for h in HOURS]
FINAL_COLS_STRUCTURE = ['cod_prov', 'name', 'sector'] + ORDERED_COLS_BASE

all_data_frames = []

# ===========================================================================
# 2. DATA INGESTION & FORMAT CONVERSION (Excel to CSV)
# ===========================================================================
excel_files = glob.glob(os.path.join(INPUT_FOLDER, "*.xlsx")) + \
              glob.glob(os.path.join(INPUT_FOLDER, "*.xls"))

print(f"Executing Batch Conversion for {len(excel_files)} files...")

for file_path in excel_files:
    try:
        df = pd.read_excel(file_path)
        clean_name = os.path.splitext(os.path.basename(file_path))[0]
        if 'name' in df.columns:
            df['name'] = clean_name
        
        csv_path = os.path.join(INPUT_FOLDER, f"{clean_name}.csv")
        df.to_csv(csv_path, index=False, sep=';', encoding='utf-8-sig')
    except Exception as e:
        print(f"Ingestion Error [{file_path}]: {e}")

# ===========================================================================
# 3. SECTORAL NORMALIZATION KERNELS
# ===========================================================================

# ---------------------------------------------------------------------------
# 3.1 Residential Sector (Res) Kernel
# ---------------------------------------------------------------------------
res_files = glob.glob(os.path.join(INPUT_FOLDER, "*.csv"))

month_map_num = {
    202401: 'gen', 202402: 'feb', 202403: 'mar', 202404: 'apr', 
    202405: 'mag', 202406: 'giu', 202407: 'lug', 202408: 'ago', 
    202409: 'set', 202410: 'ott', 202411: 'nov', 202412: 'dic'
}

for file_path in res_files:
    try:
        filename = os.path.basename(file_path)
        prov_name = os.path.splitext(filename)[0].split(' - ')[0].strip()
        
        df = pd.read_csv(file_path, sep=';')
        if 'Annomese' not in df.columns: 
            df = pd.read_csv(file_path, sep=',')
            if 'Annomese' not in df.columns:
                continue
        
        # Standardize Time Series Mapping
        df['month_str'] = df['Annomese'].map(month_map_num)
        df['hour_num'] = df['Ora'].str.replace('H', '').astype(int)
        
        # Separate Feriale (FR) and Festivo (FS) Load Profiles
        df_fr = df[df['working day'] == 'Giorno_feriale'].copy()
        df_fr['col_name'] = df_fr['month_str'] + '_fr_hour' + df_fr['hour_num'].astype(str)
        data_fr = df_fr[['col_name', 'Prelievo medio orario (kWh)']]
        
        df_fs = df[df['working day'].isin(['SAB', 'DOM'])].copy()
        df_fs_grp = df_fs.groupby(['month_str', 'hour_num'])['Prelievo medio orario (kWh)'].mean().reset_index()
        df_fs_grp['col_name'] = df_fs_grp['month_str'] + '_fs_hour' + df_fs_grp['hour_num'].astype(str)
        data_fs = df_fs_grp[['col_name', 'Prelievo medio orario (kWh)']]
        
        # Pivot to Wide Format
        row_kwh = pd.concat([data_fr, data_fs]).set_index('col_name').T
        
        # Absolute Annual Integral Calculation (Denominator)
        annual_total = 0
        for m in MONTHS_ORDER:
            n_fr, n_fs = DAYS_DATA[m]
            cols_fr = [c for c in [f"{m}_fr_hour{h}" for h in HOURS] if c in row_kwh.columns]
            cols_fs = [c for c in [f"{m}_fs_hour{h}" for h in HOURS] if c in row_kwh.columns]
            
            if cols_fr: annual_total += row_kwh[cols_fr].sum(axis=1).values[0] * n_fr
            if cols_fs: annual_total += row_kwh[cols_fs].sum(axis=1).values[0] * n_fs
        
        # Coefficient Normalization
        row_coeffs = row_kwh.div(annual_total)
        row_coeffs.insert(0, 'sector', 'res')
        row_coeffs.insert(0, 'name', prov_name)
        row_coeffs.insert(0, 'cod_prov', PROV_ID_MAP.get(prov_name, 999))
        
        all_data_frames.append(row_coeffs.reindex(columns=FINAL_COLS_STRUCTURE))
        
    except Exception as e:
        print(f"Residential Kernel Error [{filename}]: {e}")

# ---------------------------------------------------------------------------
# 3.2 Industrial Sector (Ind) Kernel
# ---------------------------------------------------------------------------
try:
    df_prof = pd.read_csv('Hourly profile_industry.csv', sep=',')
    df_prof.columns = df_prof.columns.str.strip()
    
    raw_winter = df_prof['January'].iloc[:24].values
    raw_summer = df_prof['July'].iloc[:24].values
    min_val_w, min_val_s = raw_winter.min(), raw_summer.min()
    
    # Calculate Annual Integral (assuming base load during holidays)
    total_annual_units = sum(
        (DAYS_DATA[m][0] * raw_winter.sum()) + (DAYS_DATA[m][1] * min_val_w * 24) if m in WINTER_MONTHS 
        else (DAYS_DATA[m][0] * raw_summer.sum()) + (DAYS_DATA[m][1] * min_val_s * 24)
        for m in MONTHS_ORDER
    )
    
    coeffs_fr_w, coeffs_fs_w = raw_winter / total_annual_units, min_val_w / total_annual_units
    coeffs_fr_s, coeffs_fs_s = raw_summer / total_annual_units, min_val_s / total_annual_units
    
    for prov in PROVINCES_LIST:
        row_data = prov.copy()
        row_data['sector'] = 'ind'
        for m in MONTHS_ORDER:
            target_fr, target_fs_val = (coeffs_fr_w, coeffs_fs_w) if m in WINTER_MONTHS else (coeffs_fr_s, coeffs_fs_s)
            for h_idx, h in enumerate(HOURS):
                row_data[f"{m}_fr_hour{h}"] = target_fr[h_idx]
                row_data[f"{m}_fs_hour{h}"] = target_fs_val
                
        all_data_frames.append(pd.DataFrame([row_data]).reindex(columns=FINAL_COLS_STRUCTURE))
        
except Exception as e:
    print(f"Industrial Kernel Error: {e}")

# ---------------------------------------------------------------------------
# 3.3 Services (Ser) and Agriculture (Agri) Kernel
# ---------------------------------------------------------------------------
try:
    profile_fr_common = np.array([
        15.00, 15.82, 19.45, 24.10, 30.00, 58.25, 100.00, 188.30, 
        190.45, 198.12, 205.00, 202.40, 158.40, 160.00, 205.60, 200.00, 
        190.35, 155.80, 105.00, 45.00, 40.00, 28.12, 20.00, 15.00
    ])
    
    min_val_common = profile_fr_common.min()
    profile_fs_common = np.full(24, min_val_common)
    
    total_annual_units_common = sum(
        (DAYS_DATA[m][0] * profile_fr_common.sum()) + (DAYS_DATA[m][1] * profile_fs_common.sum())
        for m in MONTHS_ORDER
    )
    
    coeffs_fr = profile_fr_common / total_annual_units_common
    coeffs_fs = profile_fs_common / total_annual_units_common
    
    for prov in PROVINCES_LIST:
        for sec in ['ser', 'agr']: # Note: 'agr' matched to SQL database standard
            row_data = prov.copy()
            row_data['sector'] = sec
            for m in MONTHS_ORDER:
                for h_idx, h in enumerate(HOURS):
                    row_data[f"{m}_fr_hour{h}"] = coeffs_fr[h_idx]
                    row_data[f"{m}_fs_hour{h}"] = coeffs_fs[h_idx]
            
            all_data_frames.append(pd.DataFrame([row_data]).reindex(columns=FINAL_COLS_STRUCTURE))
            
except Exception as e:
    print(f"Services/Agriculture Kernel Error: {e}")

# ===========================================================================
# 4. DIMENSIONAL RESHAPING (WIDE TO LONG FORMAT)
# ===========================================================================
if all_data_frames:
    print("Concatenating and Reshaping matrices...")
    
    # 4.1 Export Intermediate Wide Table
    final_wide_df = pd.concat(all_data_frames, ignore_index=True).sort_values(by=['cod_prov', 'sector'])
    final_wide_df.to_csv(OUTPUT_FILENAME_WIDE, index=False)
    
    # 4.2 Restructure via Unpivoting (pd.melt) for Relational Database Constraints
    id_vars = ['cod_prov', 'name', 'sector']
    df_long = final_wide_df.melt(id_vars=id_vars, var_name='temp_col', value_name='coefficient')
    
    df_long['month_str'] = df_long['temp_col'].apply(lambda x: x.split('_')[0])
    df_long['fr_fs'] = df_long['temp_col'].apply(lambda x: x.split('_')[1].upper())
    df_long['hour'] = df_long['temp_col'].apply(lambda x: int(x.split('_')[2].replace('hour', '')))
    
    month_map_rev = {
        'gen': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'mag': 5, 'giu': 6,
        'lug': 7, 'ago': 8, 'set': 9, 'ott': 10, 'nov': 11, 'dic': 12
    }
    
    df_long['month'] = df_long['month_str'].map(month_map_rev)
    
    # 4.3 Final Schema Alignment
    df_lookup = df_long[['cod_prov', 'month', 'fr_fs', 'hour', 'sector', 'coefficient']]
    
    # Export the final normalized long-format table
    df_lookup.to_csv(OUTPUT_FILENAME_LONG, index=False)
    print(f"Dimensional Reshaping Complete. Target relation created: {OUTPUT_FILENAME_LONG}")
else:
    print("Warning: No data frames were generated. Check input files and paths.")