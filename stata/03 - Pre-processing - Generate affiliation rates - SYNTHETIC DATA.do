/******************************************************************************* 
Title: 			Generate affiliation rates from cross-sectional data in a LOW DATA environment
Author: 		Duncan MacDonald 
Date created: 	June 2nd, 2026
Description:	For building PROST v2 pension model

	
	
Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools

Note:	We assume that the low data environment is either cross sectional monthly 
		data for the latest year, or aggregated contribution data for each active 
		individual
			
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause on
	set trace off

//	Country iso3 code
	local country  = "MEX"
	
//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local indir		 = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local homedir 	 = "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local histpopdir = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\population_obs"
	local affdir 	 = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\affiliation"

//	Simulation parameters
	local years_avg 	= 300 // 10  	// Number of years of back data that are averaged to generate 
	local minimum_age 	= 15	// Minimum age to consider (some young ages don't have a lot of data)
	
//	Name of input data
	local long_data  	 = "2 Input from client - longitudinal microdata about affiliates.dta"
 	local baseyear_data  = "synthetic_affiliates_10pct_sample.dta"	// Detailed affiliate data in the base year - synthetic data derived from aggregates
	local histpop_data   = "population_historical_MEX.dta"
	
//	Name of output data
	local affiliation_outdata = "affiliation_`country'_`years_avg'_SYNTHETIC_DATA_10pct_all_years"
	
	
	
********************************************************************************
// 	Open the cross-sectional microdata about affiliates - LOW DATA
	cd "`indir'"
	use "`baseyear_data'",clear
	
//	Get the latest year of the dataset
	summarize year
	local latest_year = r(max)

//	Generate affiliation year
//	Note: We assume that our year data is end-of-year data [and so use floor]	
	generate year_affiliated = year - floor(loa / 12)
	*generate year_affiliated = year - round(loa / 12, -1)

	
//	Compute age affilated
	generate age_affiliated = max(age - floor(loa / 12), 0) 
	*generate age_affiliated = max(age - round(loa / 12, -1), 0) 

	
//	Keep only one observation per person
	keep if month == 12
				
			
	

	
********************************************************************************	
	
//	Affiliation rates
//	Note that the longitudinal data include just affiliates 
//	It does not include those who have already retired (but who contributed in the past)
//	This is good as it shows a snapshot of individuals and when they started contributing

//	Keep only those people who newly join the system
	*keep if los == 1 & aux == 1
	
//	Collapse the data 
	*collapse (count) affiliates=id, by(year_affiliated age_affiliated gender)
	collapse (sum) affiliates=weight, by(year_affiliated age_affiliated gender)
	rename year_affiliated year
	rename age_affiliated age
	
//  Keep only the most recent years
	keep if year > `latest_year'  - `years_avg'
	keep if age >= `minimum_age'


	
//	Merge in historical population data (data is in '000s)
	cd "`histpopdir'"
	merge 1:1 year gender age using "`histpop_data'", keep(1 3) keepusing(pop) nogenerate
	
//	Compute average affiliation rates
	collapse (sum) affiliates pop, by(age gender)
	generate affiliation_rate = affiliates / (pop * 1000)		// Rate of new affiliated joining the pension system
	drop affiliates pop
	
	
	
********************************************************************************	
//	Save the dataset
//	Note: we save as a CSV so that users can adjust it
	cd "`affdir'"
	export delimited "`affiliation_outdata'.csv", replace

********************************************************************************


/*
use "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\synthetic_affiliates_01pct_sample.dta", clear
append using "C:\Users\Duncan\OneDrive\World Bank\Generic\Output\1_PROSTv2-Baseline-Affiliates-2025-2048-density_decile-synthetic-weights-allyears-affiliation-rate-June21.dta"

*append using "C:\Users\Duncan\OneDrive\World Bank\Generic\Output\1_PROSTv2-Baseline-Affiliates-2025-2048-density_decile-synthetic-weights-June21.dta"
	
//	Compute age affilated
	generate age_affiliated = max(age - floor(loa / 12), 0) 
	*generate age_affiliated = max(age - round(loa / 12, -1), 0) 

	
//	Keep only one observation per person
	keep if month == 12

	local histpopdir = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\population_obs"

//	Simulation parameters
	local minimum_age 	= 15	// Minimum age to consider (some young ages don't have a lot of data)
	
//	Name of input data
	local histpop_data   = "population_historical_MEX.dta"


//	Collapse the data 
	*collapse (count) affiliates=id, by(year_affiliated age_affiliated gender)
	collapse (sum) affiliates=weight, by(year age_affiliated gender)
	rename age_affiliated age
	
//  Keep only the most recent years
	keep if age >= `minimum_age'


	generate baseflag = (year == 2020)
	replace year = 2020
	
//	Merge in historical population data (data is in '000s)
	cd "`histpopdir'"
	merge m:1 year gender age using "`histpop_data'", keep(1 3) keepusing(pop) nogenerate
	
//	Compute average affiliation rates
	collapse (sum) affiliates pop, by(age gender year baseflag)
	generate affiliation_rate = affiliates / (pop * 1000)		// Rate of new affiliated joining the pension system
	
	reshape wide affiliation_rate, i(age gender year) j(baseflag)
	drop affiliates pop
	
