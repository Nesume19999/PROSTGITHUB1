/******************************************************************************* 
Title: 			Run preprocessing steps
Author: 		Duncan MacDonald 
Date created: 	May 7th, 2026
Description:	For building PROST v2 pension model


Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools

[TODO: Frontload the pre-processing of the longitudinal data and save it as a tempfile]
			
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause off
	set trace off



//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local homedir = "C:\Users\Duncan\OneDrive\World Bank\Generic"



********************************************************************************

// 	Generate the base-year data (affiliates)
	cd "`homedir'"
	run "01 - Pre-processing - Generate baseyear dataset.do"

	
// 	Generate the base-year data (beneficiares)
	cd "`homedir'"
	run "02 - Pre-processing - Generate beneficiary database.do"
	
	
// 	Generate affiliation rates
	cd "`homedir'"
	run "03 - Pre-processing - Generate affiliation rates.do"
	

// 	Compute modeled transition rates by duration
	cd "`homedir'"
	run "04 - Pre-processing - Estimate transitions rates.do"
	

//	Compute life-cycle wage growth profiles
	cd "`homedir'"
	run "05 - Pre-processing - Generate life cycle wage growth profiles.do"
	
	
//	Compute retirement, disability and survivor rates
	cd "`homedir'"
	run "06 - Pre-processing - Generate retirement disability survivor rates.do"

