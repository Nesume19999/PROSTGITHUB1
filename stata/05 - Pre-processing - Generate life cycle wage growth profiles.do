/******************************************************************************* 
Title: 			Generate life-cycle wage growth profiles from longitudinal data
Author: 		Duncan MacDonald 
Date created: 	April 28th, 2026
Description:	For building PROST v2 pension model (Revised)


Wage growth rates by sex, age, and wage decile

	
	
Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools

			
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause on
	set trace off

//	Country iso3 code
	local country  = "MEX"

//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local homedir 		= "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local lifecycledir 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\lifecycle wages"

//	Simulation parameters
	local minimum_age = 15	// Minimum age to consider (some young ages don't have a lot of data)
	
//	Name of input data
	local long_data  = "2 Input from client - longitudinal microdata about affiliates.dta"
	
//	Name of output data
	local lifecycle_model = "lifecycle_wages_`country'"
	
//	Parameters of the current pension system
//	We need these as we compute transition rates as a function of time to retirement
	local retcont_min = (750 / 52) * 12		// Minimum contribution threshold (in months)
	local early_retage = 60					// Earliest someone can retire

	
********************************************************************************
// 	Open the longitudinal microdata about affiliates
	cd "`homedir'"
	use "`long_data'",clear
	
			
//	Get the latest year of the dataset
	summarize year
	local latest_year = r(max)

	
// 	Sort the annual data into 5-year bands (to reduce noise)
	generate age = year - yob
	*replace  age = floor(age / 5) * 5 + 2	// Lower bound on 5-year age bands
	
	
//	Set upt the data as a time series
	generate date = ym(year, month)
	xtset id date

	
********************************************************************************
//	Build wage growth profiles by age-gender-wage_decile
********************************************************************************

//	Build a wage growth index from your own data (mean wage each year)
	bysort year: egen mean_wage_yr = mean(wage)			// Average wage in each year
	generate wage_relative_mean = wage / mean_wage_yr   // Compute the wage relative to the mean 
	sort id date										// Sort the data
	carryforward wage_relative_mean, replace			// Carry the latest non-missing data forward
	
	
// 	Deciles (using faster gtools) [Compute using relative wages, so we don't need to index]
	gquantiles wage_decile_ref_last = wage_relative_mean if year == `latest_year' & month==12 , xtile nquantiles(10) by(year) 
	bysort id: egen wage_decile_ref = max(wage_decile_ref_last)
	drop wage_decile_ref_last
	
//	Compute a reference wage decile (for those people who are not working currently)
	generate wage_decile = wage_decile_ref
	
//	Fill in observed wage_decile with 0 when not working formally
	replace  wage_decile = 0 if dens == 0 // Unemployed or working informally

	
	
********************************************************************************
//  Compute some pension-rule-specific indicators (for determining which transition matrix to use)	

//  Months of contributions requred to be eligible for an old-age pension
	generate los_gap = max(`retcont_min' - los, 0)
	
//  Drop those older workers who have enough contributions to retire 
//  (so they are not biasing our estimates of wage growth for retirement-age workers) 
	drop if los_gap == 0 & age >= `early_retage'
	
********************************************************************************
	
//  Collapse the data	
	collapse (count) obs=wage (mean) wage_relative_mean wage mean_wage_yr, by(wage_decile yob gender year)

//  Define cohorts
	egen cohort = group(yob gender wage_decile)

//  Drop those who are not working
	drop if missing(wage)
	
//  Set up the time series 
	xtset cohort year

//  Get last year's wages
	generate wage_growth_cohort = 100 * (wage - l.wage) / l.wage
	generate wage_growth_global = 100 * (mean_wage_yr - l.mean_wage_yr) / l.mean_wage_yr
	
//  Compute relational wage growth (compared with annual wage growth)
	generate wage_growth_relative = 100 * wage_growth_cohort / wage_growth_global
	
//  Define age
	generate age = year - yob
	keep if age >= `minimum_age'
	
//  Make include flag (trim extreme values)
	summarize wage_growth_relative
	local wgr_mean = r(mean)
	local wgr_sd = r(sd)
	capture drop reg_include_flag
	generate reg_include_flag = (wage_growth_relative > (`wgr_mean' - 3 * `wgr_sd') & wage_growth_relative < `wgr_mean' + 3 * `wgr_sd')
	
//  Compute the regression model 
	*regress wage_growth_relative i.wage_decile_age_sex i.gender i.age if reg_include_flag // No interactions	
	regress wage_growth_relative i.wage_decile#i.gender#i.age if reg_include_flag // Full interactions
	
// 	Save the estimates for use in the model
	cd "`lifecycledir'"
	estimates save "`lifecycle_model'", replace

********************************************************************************

	
