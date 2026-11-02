/*******************************************************************************
Title:			Convert Synthetic Baseyear Dataset from Monthly to Annual
Author:			Duncan MacDonald
Description:	Takes already generate synthetic monthly datasets and converts 
				them to annual 

Inputs:
  Synthetic datasets

Output:
  Output/synthetic_baseyear_annual.dta  - Annual versions of Synthetic dataset

Requires: gtools  (ssc install gtools)
*******************************************************************************/

//	INITIALIZATION
	clear all
	pause on
	set trace off


// =============================================================================
//	SECTION 0: USER PARAMETERS  
// =============================================================================
	
	// File locations
	local indir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"	// User inputs

	//	File paths
	local synthetic_data  "synthetic_affiliates_1pct_sample"




// =============================================================================
//	SECTION 1: AGGREGATE MONTHLY DATA INTO ANNUAL DATA
// =============================================================================

	// Open the dataset
	cd "`indir'"
	use "`synthetic_data'.dta", clear
	
	// Collapse the dataset
	collapse (max) los loa iacc status spell_length  ///
			 (sum) dens ///
			 (mean) weight wage reference_wage, ///
			 by(year gender id age yob pension_class wage_decile_ref)
	
	// Replace wage deciles
	generate wage_decile = wage_decile_ref if dens > 0 
	
	//  We need to rebuild the wage deciles by age and sex after aggregating (it varies throught the year)
	//	Build a wage growth index from your own data (mean wage each year)
	bysort year: egen mean_wage_yr = mean(wage)							// Average wage in each year
	generate wage_relative_mean = wage / mean_wage_yr     				// Compute the wage relative to the mean
	sort id year														// Sort the data
	carryforward wage_relative_mean, replace							// Carry the latest non-missing data forward	
	
	//  Compute the wage deciles within age and gender
	display "Computing wage deciles within age and gender..."
	gquantiles wage_decile_age_sex = wage_relative_mean , xtile nquantiles(10) by(year age gender) // Deciles (using faster gtools)
	drop wage_relative_mean mean_wage_yr

	
	// Save the dataset
	save "`synthetic_data'_annualized.dta", replace
	
