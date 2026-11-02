/******************************************************************************* 
Title: 			Generate generic beneficiary database from detailed beneficiary microdata
Author: 		Duncan MacDonald 
Date created: 	April 4th, 2026
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

	local ben_data  = "3 Input from client - microdata about beneficiaries"


********************************************************************************
// 	Open the beneficiary microdata about affiliates
	cd "`homedir'"
	use "`ben_data'", clear
	
//	Note: There are a lot of duplicates in this dataset
//	[TODO: Ask Marola about this. Why are they there, and why is iden not unique]



//	Some pension types are missing. 
//	[TODO: Ask Marola what to do about them?]
//	Note: For now, I drop them as dropping them aligns my counts with aggregate totals provided separately
	drop if type == ""

//	Generate a pension class indicator (DB or DC)
	generate pension_class = .
	replace  pension_class = 1 if inlist(type, "B", "C", "D")
	replace  pension_class = 2 if inlist(type, "E", "F", "G")
	
	label define pension_class_LAB 1 "DB" 2 "DC"
	label values pension_class pension_class_LAB
	
	label variable pension_class "Class of pension (e.g., DB, DC, etc.)"

	
//	Generate an indicator of the type of pension (old-age, disability, survivor)
	generate pension_type = .
	replace  pension_type = 1 if inlist(type, "B", "E")
	replace  pension_type = 2 if inlist(type, "C", "F")
	replace  pension_type = 3 if inlist(type, "D", "G")
	
	label define pension_type_LAB 1 "Old-age" 2 "Disability" 3 "Survivor"
	label values pension_type pension_type_LAB
	
	label variable pension_type "Type of pension (old-age, disability, surivior)"
	
//	Generate an indicator of the type of pension (old-age, disability, survivor)
	generate pension_id = .
	replace  pension_id = 1 if type == "B"
	replace  pension_id = 2 if type == "C"
	replace  pension_id = 3 if type == "D"
	replace  pension_id = 4 if type == "E"
	replace  pension_id = 5 if type == "F"
	replace  pension_id = 6 if type == "G"
	
	label variable pension_id "Pension type and class identifier"
	
	label define pension_id_LAB ///
		1 "Old-age - DB" ///
		2 "Disability - DB" ///		
		3 "Survivor - DB" ///
		4 "Old-age - DC" ///
		5 "Disability - DC" ///
		6 "Survivor - DC" //
	label values pension_id pension_id_LAB
	
//	Rename some variables
	rename monthlybenefit pension_benefit
	label variable pension_benefit "Monthly pension benefit"

	
//	Cleanup
	drop iden // This value is not unique anyway
	drop type // This is already reclassified

	

// Save the dataset
	cd "`inputdir'"
	save pensioners_`country'.dta, replace


	
	
********************************************************************************
