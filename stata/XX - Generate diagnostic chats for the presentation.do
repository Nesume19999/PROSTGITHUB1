/******************************************************************************* 
Title: 			Diagnostic charts
Author: 		Duncan MacDonald 
Date created: 	June 18th, 2026
Description:	Here we build data for charts to be used for diagnostics

Status variable
	- 1  = alive and affiliated
	- 2  = retired
	- 3  = disabled
	- 4  = widowed
	- 99 = dead
	

		
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause off
	set trace off
	timer on 1


//	SET THE SIMULATION NAME
	local simname 		= "Baseline"
	local country		= "MEX"
	
//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local indir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"							// User inputs
	local outdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Output\ChartData"				// Diagnostic outputs
	
//	Names of input databases
 	local baseyear_data  	 = "synthetic_affiliates_01pct_sample.dta"	// Detailed affiliate data in the base year - synthetic data derived from aggregates
	local pensioners_data	 = "synthetic_pensioners_01pct_sample.dta"	// Detailed pensioner data in the base year - synthetic data derived from aggregates
	
//	Name of outputs
	local outname = "XX-Diagnostic-Charts-baseyear-01pct-sample"
	
********************************************************************************

	//	Load the baseyear data into memory
	cd "`indir'"
	use "`baseyear_data'", clear
	
	// Distribution of pension class
	cd "`outdir'"	
	table pension_class, statistic(count id)
	collect export "`outname'.xlsx", sheet("pension_class", replace) as(xlsx) update
	
	// Distribution of pension class by age
	cd "`outdir'"	
	table age pension_class, statistic(count id)
	collect export "`outname'.xlsx", sheet("pension_class_age", replace) as(xlsx) update
	
	// Distribution of pension class by gender
	cd "`outdir'"	
	table gender pension_class, statistic(count id)
	collect export "`outname'.xlsx", sheet("pension_class_sex", replace) as(xlsx) update

	

	// Generate histogram data 
	