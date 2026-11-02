/******************************************************************************* 
Title: 			Estimate turnover rates rates from longitudinal data
Author: 		Duncan MacDonald 
Date created: 	June 19th, 2026
Description:	For building PROST v2 pension model (Revised)

*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause on
	set trace off

//	Country iso3 code
	local country  = "MEX"

//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local homedir 		= "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local indir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local outdir        = "C:\Users\Duncan\OneDrive\World Bank\Generic\Output\Diagnostic Charts"

//	Name of input data	
	local long_data  = "2 Input from client - longitudinal microdata about affiliates.dta"
	local weight_data	= "synthetic_weights_10pct_sample.dta"



//	Simulation parameters
	local samplesize  = 10		// Sample size of the projection database (100 is a full sample, 1 is a 1% sample) - [Only when testing]



********************************************************************************
// 	Open the longitudinal microdata about affiliates
	cd "`homedir'"
	use "`long_data'", clear
	
//	Merge in the weights
	cd "`indir'"
	merge m:1 id using `weight_data', nogenerate
	replace weight = 0 if missing(weight)
	
	
//	Get the latest year of the dataset
	summarize year
	local latest_year = r(max)
	local earliest_year = r(min)

// 	Sort the annual data into 5-year bands (to reduce noise)
	generate age = year - yob
	
//	Minor cleanup
	rename aux loa
	label variable loa "Length of affiliation (months)"
	
	
********************************************************************************

// // 	There is too much data for the model to run in a reasonable time during testing
// // 	We need to sample people, but they have multiple observations in the base dataset
// //	[TODO: Consider a stratified sample]
// 	preserve
// 		tempfile sample_merge
// 		keep id
// 		duplicates drop
// 		sample `samplesize'
// 		generate sampled = 1
// 		save `sample_merge'
// 	restore
//
// 	//	Merge the sample back into the dataset to determine who to keep
// 	join sampled, from(`sample_merge') by(id) keep(1 3) nogenerate // ftools version of merge [faster]
// 	keep if sampled == 1
// 	drop sampled

********************************************************************************
//	Compute spells of unemployment and job tenure

//	Set up time series data
	generate date = ym(year, month)
	sort id date




********************************************************************************
// 	Compute transition rates
	
// 	Set up the time series
	xtset id date
	
// 	Get the last period of deciles and wages
	generate next_dens  = f.dens
	
// 	Compute the current and previous states	
	generate current_state	= (dens > 0)		// Indicator of if person contributed
	generate next_state	  	= (next_dens > 0)	// Indicator of if person contributed
	
// 	Compute the transitions in and out of active contributions
	generate transition_in  = (current_state == 0 & next_state == 1) if current_state == 0	// Indicator: transitioned in 
	generate transition_out = (current_state == 1 & next_state == 0) if current_state == 1	// Indicator: transitioned out
	
//	Clean up transition rates at the end of the observation window
	replace transition_in  = . if year == `latest_year' & month == 12	
	replace transition_out = . if year == `latest_year' & month == 12
	
//	Generate a turnover indicator (transitioned in or out)
	capture drop turnover
	generate turnover = (transition_in ==1 | transition_out ==1)
	generate turnover_wgt = turnover * weight
	
	
//	Unweighted turnover rate
	tab year turnover, row nofreq	
	
//	Turnover rate weighted by synthetic data weights
	table year, stat(sum turnover_wgt weight)	


	