/******************************************************************************* 
Title: 			Generate affiliation rates from longitudinal data
Author: 		Duncan MacDonald 
Date created: 	March 18th, 2026
Description:	For building PROST v2 pension model

	
	
Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools

Revision: 	Rather than assign people to deciles according to where they are in the data, 
			We compute a person's position within age-gender-wage-decile cells
			
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause on
	set trace off

//	Country iso3 code
	local country  = "MEX"
	
//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local homedir 	 = "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local histpopdir = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\population_obs"
	local affdir 	 = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\affiliation"

//	Simulation parameters
	local years_avg 	= 10  	// Number of years of back data that are averaged to generate 
	local minimum_age 	= 15	// Minimum age to consider (some young ages don't have a lot of data)
	
//	Name of input data
	local long_data  	= "2 Input from client - longitudinal microdata about affiliates.dta"
	local histpop_data = "population_historical_MEX.dta"
	
//	Name of output data
	local affiliation_outdata = "affiliation_`country'_`years_avg'"
	

	
********************************************************************************
// 	Open the longitudinal microdata about affiliates
	cd "`homedir'"
	use "`long_data'",clear
	
//	Generate date variable
	generate date = ym(year, month)
	
			
//	Get the latest year of the dataset
	summarize year
	local latest_year = r(max)
	local earliest_year = r(min)

	
// 	Sort the annual data into 5-year bands (to reduce noise)
	generate age = year - yob				
	keep if age >= `minimum_age'
	*replace  age = floor(age / 5) * 5 + 2	// Lower bound on 5-year age bands
				
	

********************************************************************************

//  Keep only the most recent years
	keep if year > `latest_year'  - `years_avg'

	
********************************************************************************	
	
//	Affiliation rates
//	Note that the longitudinal data include just affiliates 
//	It does not include those who have already retired (but who contributed in the past)
//	This is good as it shows a snapshot of individuals and when they started contributing

//	Keep only those people who newly join the system
	keep if los == 1 & aux == 1
	
//	Collapse the data 
	collapse (count) affiliates=id, by(year age gender)

//	Drop the earliest year (as the the program is just developing and affiliation will be overstated)
	drop if year == `earliest_year'
	
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
