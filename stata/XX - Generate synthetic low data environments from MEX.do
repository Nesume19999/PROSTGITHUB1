/******************************************************************************* 
Title: 			Generate synthetic low-data environments
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
	local homedir 	 = "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local outdir	 = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"


//	Name of input data
	local long_data  	= "2 Input from client - longitudinal microdata about affiliates.dta"
	local histpop_data = "population_historical_MEX.dta"
	
//	Name of output data
	local low_data 		= "lowdata_`country'"
	local very_low_data = "verylowdata_`country'"
	local extremely_low_data = "extremelylowdata_`country'"


	

	
********************************************************************************
// 	Open the longitudinal microdata about affiliates
	cd "`homedir'"
	use "`long_data'",clear
	
			
//	Get the latest year of the dataset
	summarize year
	local latest_year = r(max)	
	keep if year == `latest_year'

	
********************************************************************************	
//	Save the low data environment dataset (final year cross sectional data)
	cd "`outdir'"
	save "`low_data'.dta", replace

	
	
********************************************************************************
//	Collapse the data to generate very low data environment
	collapse (sum) dens (max) aux los iacc (mean) wage, by(id gender yob year)


********************************************************************************	
//	Save the very low data environment dataset (final year cross sectional data)
	cd "`outdir'"
	save "`very_low_data'.dta", replace

	
	
********************************************************************************
//	Drop those that don't contribute in this year
	drop if dens == 0


********************************************************************************	
//	Save the very low data environment dataset (final year cross sectional data)
	cd "`outdir'"
	save "`extremely_low_data'.dta", replace
