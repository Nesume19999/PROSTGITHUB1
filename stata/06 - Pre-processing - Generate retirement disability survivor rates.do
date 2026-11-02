/******************************************************************************* 
Title: 			Use Detailed Beneficiary rate to generate retirement rates, 
				disability rates, and survivor rates
Author: 		Duncan MacDonald 
Date created: 	April 2th, 2026
Description:	For building PROST v2 pension model



			
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause on
	set trace off
	
//	Country iso3 code
	local country  = "MEX"


//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local homedir 		= "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local inputdir		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local mortdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\mortality_obs"		// Default historical mortality data
	local affdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\affiliation"			// Affiliation data
	local disabilitydir	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\disability"
	local survivordir	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\survivor"
	local retiredir		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\retirement"

	local histpopdir 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\population_obs"

//	Input data names
	local ben_data  		= "pensioners_MEX"
	local histpop_data 		= "population_historical_MEX"
	local mortality_data	= "mortality_obs_MEX.csv"		// Mortality rates
	local affiliation_data 	= "affiliation_MEX.csv"		// Affiliate rates derived from the longitudinal data

//	Output data names
	local oa_out_name 		= "retirement_rates_`country'"
	local disa_out_name 	= "disability_rates_`country'"
	local survivor_out_name = "survivor_rates_`country'"
	
//	Design parameters
	local include_years = 20	// Number of years to average over

	
********************************************************************************
//	Build the affiliation rates into memory

	// Import and save the affilation data
	cd "`affdir'"
	import delimited "`affiliation_data'", clear
	tempfile affiliation_rate
	save `affiliation_rate', replace
	
	
********************************************************************************
//	Next, we need to get cumulative mortality rates by year
//	We will observe pension stocks in the base year as well as when they started
//	Some people will have died since starting a pension, and we need to account for that

//	Open the mortality data
	cd "`mortdir'"
	import delimited "`mortality_data'",clear
	
// 	Generate a gender variables
	capture drop gender
	generate gender = .
	replace  gender = 1 if sex == "male"
	replace  gender = 2 if sex == "female"
	
// 	Reshape to get the year range
//	Note: This is only to get the year range
	reshape long y, i(iso3 location variable age sex) j(year)
	rename y mortality_rate
	
	

********************************************************************************
// Backfill early mortality rates using earlies rates

// Step 0: 
	quietly summarize year
	local start_year = r(min)
	local end_year = r(max)

	// Preserve the data for 
	preserve
		// Step 1: Keep only earliest records as the template for backfilling
		keep if year == `start_year'

		// Step 2: Expand each observation into 101 copies
		//         (1 original + 100 new years: 1850-1949)
		expand 101

		// Step 3: Assign years 1850-1950 to the expanded records
		bysort gender age (year): replace year = `start_year' - 101 + _n

		// Verify: should run from 1850 to 1950 (drop the duplicate 1950 — kept in main data)
		drop if year == 1950

		// Step 4: Save as tempfile to append back to main data
		tempfile pre`start_year'
		save `pre`start_year''
	restore

// Step 5: Append backfilled records and re-sort
	append using `pre1950'
	gsort gender age year
		
	
********************************************************************************

// Step 1: Identify cohort (birth year)
	generate birth_year = year - age

// Step 2: Sort along the cohort diagonal (birth_year constant, age/year increment together)
	gsort gender birth_year age

// Step 3: Log survival increment at each age/year cell
	tempvar log_surv_increment
	generate `log_surv_increment' = log(1 - mortality_rate)

// Step 4: Cumulative sum along the cohort diagonal
//         bysort gender birth_year (age) follows each cohort through time
	tempvar cum_log_surv
	bysort gender birth_year (age): generate `cum_log_surv' = sum(`log_surv_increment')

// Step 5: Exponentiate to recover cohort survival probability
	generate survival_rate = exp(`cum_log_surv')
	label variable survival_rate "Cohort survival S(a) = prod(1 - q(x, b+x))"


********************************************************************************
	

//	Cleanup and reshape
	drop mortality_rate
	replace variable = "survival"
	
//	Save the dataset
	tempfile survival_rates
	save `survival_rates', replace
	
	


********************************************************************************
********************************************************************************
********************************************************************************
// 	Open the beneficiary microdata about affiliates
//	Note: This is after any preprocessing steps
//	Data has the following variables: pension_ben age gender startyear pension_class pension_type pension_id
	cd "`inputdir'"
	use "`ben_data'",clear
	
//	Minor cleanup
	rename startyear year
	replace age = 100 if age > 100	// This is because other values are topcoded
	
//	Collapse the data	
	collapse (count) tally = pension_id, by(age gender year pension_type)
	
//	Reshape to wide (by pension type)
	reshape wide tally, i(age gender year) j(pension_type)
	
	replace tally1 = 0 if missing(tally1)
	replace tally2 = 0 if missing(tally2)
	replace tally3 = 0 if missing(tally3)

	rename tally1 oa_pension
	rename tally2 disa_pension
	rename tally3 survivor_pension
	
//	Generate age when start receiving a pension
	quietly summarize year
	local baseyear = r(max)
	generate age_start = max(age - (`baseyear' - year), 0)
	
//	Swap age at start and age now to help our merge
	rename age age_now
	rename age_start age
	

//	Merge in historical population data (data is in '000s)
	cd "`histpopdir'"
	merge m:1 year gender age using `histpop_data', keep(1 3) keepusing(pop) nogenerate
	
//	Merge in the survival rate data (we need to adjust for the fact that some people die from the time since they start receiving a pension)
	merge m:1 year age gender using  `survival_rates', keep(1 3) keepusing(survival_rate) nogenerate
	rename survival_rate survival_rate_start
	
//	Merge in the cohort survival rate data (we need to adjust for the fact that some people die from the time since they start receiving a pension)
	rename age start_age
	rename age_now age
	rename year startyear
	generate year = `baseyear'
	merge m:1 year age gender using  `survival_rates', keep(1 3) keepusing(survival_rate) nogenerate
	rename survival_rate survival_rate_now
	
//	Drop those observations that are far in the past (and we have no population data for)
	drop if missing(pop)
	
//	Swap back the age names
	rename age age_now
	
//	Compute the original cohort rates using conditional probabilities
	generate oa_pension_adj 		= oa_pension 		/ (survival_rate_now / survival_rate_start)
	generate disa_pension_adj 		= disa_pension 		/ (survival_rate_now / survival_rate_start)
	generate survivor_pension_adj 	= survivor_pension	/ (survival_rate_now / survival_rate_start)
	
	label variable oa_pension_adj 		"Number of old-age pension entrants: adjusted for conditional survial rates"
	label variable disa_pension_adj 	"Number of disability pension entrants: adjusted for conditional survial rates"
	label variable survivor_pension_adj "Number of survivor pension entrants: adjusted for conditional survial rates"
	
//	Compute the pension entrance rates in terms of population (Note: population in in '000s)
	generate oa_rate_pop 		= oa_pension_adj   / (pop * 1000)
	generate disa_rate_pop 		= disa_pension_adj / (pop * 1000)
	generate survival_rate_pop 	= oa_pension_adj   / (pop * 1000)
	
//	Keep only those years that we want to include (the most recent ones)
	drop year
	rename startyear year
	keep if year >= `baseyear' - `include_years'
	
	
//	Compute the average rates by population
	rename age_now age
	collapse (mean) oa_rate_pop disa_rate_pop survival_rate_pop, by(age gender)
	
	label variable oa_rate_pop 		 "Old age pension entrance rate - in terms of population"
	label variable disa_rate_pop 	 "Disability pension entrance rate - in terms of population"
	label variable survival_rate_pop "Survivor pension entrance rate - in terms of population"
	
//	Imply retirement age from the retirement data
//	Note: We want to restate retirement rates as a function of the retirement age 
	
	
********************************************************************************
	
//	Cleanup	
	keep age gender oa_rate_pop disa_rate_pop survival_rate_pop // oa_rate_aff disa_rate_aff survival_rate_aff
	
//	Save the different rates
	preserve
		cd "`retiredir'"
		keep age gender oa_rate_pop
		export delimited "`oa_out_name'.csv", replace
	restore

	preserve
		cd "`disabilitydir'"
		keep age gender disa_rate_pop
		export delimited "`disa_out_name'.csv", replace
	restore
	
	preserve
		cd "`survivordir'"
		keep age gender survival_rate_pop
		export delimited "`survivor_out_name'.csv", replace
	restore
	
	


	
	
********************************************************************************
