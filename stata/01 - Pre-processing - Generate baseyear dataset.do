/******************************************************************************* 
Title: 			Get the baseyear affiliate microdata
Author: 		Duncan MacDonald 
Date created: 	March 27th, 2026
Description:	For building PROST v2 pension model


Note: This code uses the ssc packages carryforward, gtools and ftools:

ssc install carryforward
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
	local homedir 	= "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local indir 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"

//	Name of input data
	local long_data = "2 Input from client - longitudinal microdata about affiliates.dta"

//	Name of output data
	local outname 	= "baseyear_data_`country'"


********************************************************************************
//	GET THE BASEYEAR DATASET - ONLY NEED TO RUN ONCE
// 	Open the longitudinal microdata about affiliates
	cd "`homedir'"
	use "`long_data'", clear
	
//	Get the latest year of the dataset
	summarize year
	local latest_year = r(max)
		
//	Minor cleanup
	rename aux loa
	label variable loa "Length of affiliation (months)"
	
// 	Compute the age
	generate age = year - yob
	
	
********************************************************************************
//	Compute spells of unemployment and job tenure
//	Set up time series data
	generate date = ym(year, month)
	sort id date

//	Identify the start of a new spell (status change or new person)
	generate byte new_spell = (dens != dens[_n-1] | id != id[_n-1])
	
//	Create a unique ID for every single spell in the dataset
	generate spell_id = sum(new_spell)
	drop new_spell

//	Calculate the length of every spell
	bysort spell_id: generate spell_length = _N
	drop spell_id
	
********************************************************************************	
	
//	Build a wage growth index from your own data (mean wage each year)
	bysort year: egen mean_wage_yr = mean(wage)							// Average wage in each year
	generate wage_relative_mean = wage / mean_wage_yr     				// Compute the wage relative to the mean
	sort id date														// Sort the data
	carryforward wage_relative_mean, replace							// Carry the latest non-missing data forward
	
//  Deciles (using faster gtools) [Compute using relative wages, so we don't need to index]
	gquantiles wage_decile_ref_last = wage_relative_mean if year == `latest_year' & month==12 , xtile nquantiles(10) by(year) 
	bysort id: egen wage_decile_ref = max(wage_decile_ref_last)
	drop wage_decile_ref_last
	
//	Compute a reference wage decile (for those people who are not working currently)
	generate wage_decile = wage_decile_ref
	
//	Fill in observed wage_decile with 0 when not working formally
	replace  wage_decile = 0 if dens ==0 // Unemployed or working informally
	
//  Compute the wage deciles within age and gender
	display "Computing wage deciles within age and gender..."
	gquantiles wage_decile_age_sex = wage_relative_mean , xtile nquantiles(10) by(year age gender) // Deciles (using faster gtools)


//	Convert wages from daily to monthly (assumed 20 workdays in a week)
	replace wage = wage * 20
	
********************************************************************************
	
//	Keep only the latest year
	keep if year == `latest_year'

//	Determine a status [1=alive, 2=dead, 3=disabled, 4=widowed]
	generate status = 1	// Everyone starts alive
	
//	Add a pension class indicator
	generate penson_class = 2 // DC pension plan
	
//	Save the baseyear dataset	
	cd "`indir'"
	save "`outname'.dta", replace
	
	
	
********************************************************************************