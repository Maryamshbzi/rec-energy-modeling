"""
===========================================================================
ARERA DOMESTIC CONSUMPTION AGGREGATOR
===========================================================================
Description: 
This script processes raw monthly electricity withdrawal data for domestic 
clients (sourced from ARERA). It iterates through provincial Excel files, 
extracts monthly consumption values (kWh), calculates the annual integral, 
and generates a consolidated relational dataset for PostgreSQL ingestion.
===========================================================================
"""

import os
import glob
import pandas as pd

# ===========================================================================
# 1. CONFIGURATION & MAPPING
# ===========================================================================
# ISTAT Provincial Codes mapping (covers Puglia, Calabria, and Sicily)
PROVINCE_CODES = {
    # Puglia
    'Foggia': 71, 'Bari': 72, 'Taranto': 73, 'Brindisi': 74, 
    'Lecce': 75, 'Barletta-Andria-Trani': 110,
    # Calabria
    'Cosenza': 78, 'Catanzaro': 79, 'Reggio di Calabria': 80, 
    'Crotone': 101, 'Vibo Valentia': 102,
    # Sicily
    'Trapani': 81, 'Palermo': 82, 'Messina': 83, 'Agrigento': 84,
    'Caltanissetta': 85, 'Enna': 86, 'Catania': 87, 'Ragusa': 88, 'Siracusa': 89
}

# Define the specific prefix used in the raw downloaded files
FILE_PREFIX = "Bar chart colour gradient vertical - Annomese 2 "
OUTPUT_FILE = "Prelievo_Medio_Consolidato.xlsx"
REFERENCE_YEAR = 2024

MONTHS_COLS = [
    'jan_kwh', 'feb_kwh', 'mar_kwh', 'apr_kwh', 
    'may_kwh', 'jun_kwh', 'jul_kwh', 'aug_kwh', 
    'sep_kwh', 'oct_kwh', 'nov_kwh', 'dec_kwh'
]

# ===========================================================================
# 2. DATA EXTRACTION AND PROCESSING
# ===========================================================================
def process_arera_data():
    consolidated_data = []
    
    # Locate all relevant Excel files in the directory
    search_pattern = f"{FILE_PREFIX}*.xlsx"
    files = glob.glob(search_pattern)
    
    print(f"Found {len(files)} files matching the pattern. Commencing extraction...")

    for file in files:
        # Extract province name by stripping the prefix and extension
        filename = os.path.basename(file)
        province_name = filename.replace(FILE_PREFIX, "").replace(".xlsx", "").strip()
        
        # Assign ISTAT code (default to 0 if not found)
        prov_code = PROVINCE_CODES.get(province_name, 0) 
        
        try:
            df = pd.read_excel(file)
        except Exception as e:
            print(f"Error reading {filename}: {e}")
            continue
        
        # Initialize data dictionary for the current province
        row_data = {
            'code_prov': prov_code,
            'den_uts': province_name,
            'year': REFERENCE_YEAR
        }
        
        yearly_total = 0.0
        
        # Extract monthly data assuming chronological order in the first 12 rows
        # and the value located in the second column (index 1)
        for i in range(min(12, len(df))):
            try:
                # iloc[row_index, col_index]
                kwh = float(df.iloc[i, 1]) 
                row_data[MONTHS_COLS[i]] = kwh
                yearly_total += kwh
            except (ValueError, TypeError):
                # Handle empty cells or non-numeric data gracefully
                row_data[MONTHS_COLS[i]] = 0.0
                
        row_data['yearly_kwh'] = yearly_total
        consolidated_data.append(row_data)

    # ===========================================================================
    # 3. EXPORT CONSOLIDATED DATASET
    # ===========================================================================
    if consolidated_data:
        final_df = pd.DataFrame(consolidated_data)
        
        # Ensure columns are ordered logically
        cols_order = ['code_prov', 'den_uts', 'year'] + MONTHS_COLS + ['yearly_kwh']
        final_df = final_df[[c for c in cols_order if c in final_df.columns]]
        
        final_df.to_excel(OUTPUT_FILE, index=False)
        print(f"Successfully consolidated data into: {OUTPUT_FILE}")
    else:
        print("Warning: No data was processed. Please verify the input files.")

if __name__ == "__main__":
    process_arera_data()