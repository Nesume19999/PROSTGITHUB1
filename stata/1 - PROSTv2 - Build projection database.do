/******************************************************************************* 
Title: 			Build projection dataset
Author: 		Duncan MacDonald 
Date created: 	March 27th, 2026
Description:	For building PROST v2 pension model (adjusted for April 2026 model concept)

Status variable
	- 1  = alive and affiliated
	- 2  = retired
	- 3  = disabled
	- 4  = widowed
	- 99 = dead
	
Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools

		
TODO: Add into an ado file
TODO: Create GUI
		
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause off
	set trace off
	timer on 1

// 	SETS THE SEED OF THE RANDOM NUMBER GENERATOR
//	Note: Any seed works the same. 
//	The idea is to set it to one specific value so to have the same resuts when the model is re-run
	set seed 2
	
//	SPEED SETTINGS
	// Uses float variables rather than double - less space than double (increases speed)
	set type float	
	// Ensure that all processores are being used
	local max_processors = c(processors_max)
	set processors `max_processors'

//	SET THE SIMULATION NAME
	local simname 		= "Presentation_05pct"
	local country		= "MEX"
	
//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local indir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"							// User inputs
	local outdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Output"							// Projection outputs
	local popdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\population"		// Default population data
	local mortdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\mortality"		// Default mortality data
	local lifedir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\life-expectancy"	// Default life expectancy data
	local affdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\affiliation"		// Affiliation data
	local transdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\transitions"		// Transition matrix
	local wagegrowdir 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"		// Wage growth projections
	*local wagegrowdir 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\wage_growth"		// Wage growth projections
	local lifecycledir 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\lifecycle wages"	// Relative wage growth for different groups (age-gender-decile)


//	Names of input databases
 	*local baseyear_data  	 = "baseyear_data_MEX.dta"					// Detailed affiliate data in the base year
	*local pensioners_data	 = "pensioners_MEX.dta"						// Detailed pensioner data in the base year
 	local baseyear_data  	 = "synthetic_affiliates_05pct_sample.dta"	// Detailed affiliate data in the base year - synthetic data derived from aggregates
	local pensioners_data	 = "synthetic_pensioners_05pct_sample.dta"	// Detailed pensioner data in the base year - synthetic data derived from aggregates
 	*local baseyear_data  	 = "synthetic_affiliates_empty.dta"			// Detailed affiliate data in the base year - empty dataset for debugging
	*local pensioners_data	 = "synthetic_pensioners_empty.dta"			// Detailed pensioner data in the base year - empty dataset for debugging
	*local affiliation_data  = "affiliation_MEX_10.csv"					// Affiliate rates derived from the longitudinal data
	local affiliation_data  = "affiliation_MEX_10_SYNTHETIC_DATA_10pct.csv"	// Affiliate rates derived from the synthetic data
	*local affiliation_data 	 = "affiliation_MEX_300_SYNTHETIC_DATA_10pct_all_years.csv"	// Affiliate rates derived from the synthetic data - Note we use the All Years version to try to see if we can match the baseyear affiliation rate [just for diagnostics]
	local population_data 	 = "population_MEX.csv"						// Population projections
	local mortality_data	 = "mortality_MEX.csv"						// Mortality rates
	local life_expect_data	 = "life_expectancy_MEX.csv"				// Age-conditional life expectancy
	local decile_wage_data 	 = "decile_wages_MEX.csv"					// Decile wage distributions derived from baseyear_data (mean, sd, min, max) 
	*local transitions_data	 = "transitions_MEX_15_groups.dta"			// Wage dynamics transitions matrix
	local lm_assumptions	 = "labor_market_assumptions.csv"			// Labour market assumptions over the projection (turnover_target, emp_rate_growth)
	*local lm_assumptions	 = "labor_market_assumptions_obs.csv"		// Labour market assumptions over the projection (turnover_target, emp_rate_growth)
	local index_assummptions = "indexation_assumptions_MEX.csv"			// Wage and Benefit Indexation Assumptions over the projection
	local wage_grow_data 	 = "wage_growth_MEX.csv"					// Assumed wage growth by year
	*local wage_grow_data 	 = "cpi_MEX.csv"							// Assumed wage growth by year

	
//	Transition model data
	*local job_exit_model 	= "job_exit_model_MEX_10_final" 	// "job_exit_model_MEX_10_last" // "job_exit_model_MEX_10_final"
	*local job_entry_model 	= "job_entry_model_MEX_10_final"	// "job_entry_model_MEX_10_last_cod_log" //  job_entry_model_MEX_10_final"
	*local job_exit_model 	= "job_exit_model_MEX_10_densdecile_1pct_synthetic" 	// "job_exit_model_MEX_10_last" // "job_exit_model_MEX_10_final"
	*local job_entry_model 	= "job_entry_model_MEX_10_densdecile_1pct_synthetic"	// "job_entry_model_MEX_10_last_cod_log" //  job_entry_model_MEX_10_final"
	local job_exit_model 	= "job_exit_model_MEX_10_spellsquare_1pct_synthetic" 	// "job_exit_model_MEX_10_last" // "job_exit_model_MEX_10_final"
	local job_entry_model 	= "job_entry_model_MEX_10_spellsquare_1pct_synthetic"	// "job_entry_model_MEX_10_last_cod_log" //  job_entry_model_MEX_10_final"

//	Wage model data
	*local lifecycle_model 	= "lifecycle_MEX_10"			// Model estimates for wage growth - dummies for age
	local lifecycle_model 	= "lifecycle_wages_MEX_cage" 	// Model estimates for wage growth - continuous age
	
//  Topcode age at the edge of reliable data so the lifecycle model is never asked to extrapolate beyond where we actually observe wage growth
	local max_reliable_age = 60	// Choose the early retirement age so that wage growth is not impacted by retirement decisions
	local wage_stats_max_age_grp = 65	// Pool wage stats for all ages >= this into one band (thin data for older/retired workers)
	

// 	Define contribution pension input file (excel workbook with multiple sheets)
	local dc_parameters_data 	= "dc_parameters_`country'.xlsx"	// Defined-contribution policy parameters
	local db_parameters_data 	= "db_parameters_`country'.xlsx"	// Defined-benefit policy parameters
	
	

//	Simulation parameters
	local baseyear = 2024
	local horizon = 80 // 80 				// Number of projection years (default is 80)
	local startyear = `baseyear' + 1		// First year of the projection
	local endyear = `baseyear' + `horizon'	// Last year of the projection
	local samplesize = 1					// Sample size of the projection database (100 is a full sample, 1 is a 1% sample)
	local max_eligibility_age = 75			// [User defined] Cut-off year by which people have no reasonable hope of acquiring more pension time
	local extended_output = 0				// Toggle on and off extended output (output of the entire simulation)
	local histograms = 0					// Toggle on and off histograms
	
	local working_age_min	= 15			// Minimum age to be considered working age
	local working_age_max	= 64			// Maximum age to be considered working age
	*local wage_adjustment	= 9878.469 / 7048.628	// Wage adjustment to bring 2020 data to 2024 baseyear (monthly earnings growth from the ILO)
	local wage_adjustment	= 1				// Because we are using the synthetic data that match average wages, we do not adjust wages [Aggregate data is from 2024]
	local too_old_to_retire = 75			// Age at which people retire if they haven't already

	



	
//	Labour market parameters
//	See Step 1.7
//	Note: the key anchors of emp_rate_growth and turnover_target are imported from user-maintained csv files




********************************************************************************
********************************************************************************
//	DB Pension policy parameters
//	See Step 1.12 - Parameters loaded in via excel sheets
	
	
//	DB pension policy parameters
//	All time-varying parameters (retirement ages, service requirements, accrual rates,
//	min/max pension rules, indexation coefficients) are loaded from:
//	  db_parameters_`country'.xlsx  ->  STEP 1.12
//	and resolved at the start of each projection year in the annual loop.
//	Only structural parameters that cannot change mid-simulation are set here.

//	Reference Wage
//	ReferenceWage_i = 1/N Sum_(j in SelectedYears) ValorizedWage_i(j)
	local ref_wage_n = 5	// How many years to consider
	local ref_wage_m = 100	// How many of the last years to consider
	local ref_wage_type = 1 // Type of calculation:
	// 1 = Last N years before retirement
	// 2 = Best N years in the career
	// 3 = Best N years within the last M years before retirement
	// NOTE: ref_wage_n/m/type govern how many bestwage* variables are created in Step 2.
	//       Changing them mid-simulation is not supported; set once here.

********************************************************************************
//	DC pension parameters
//	See Step 1.11 - Parameters loaded in via excel sheets

//	Implementation year of the pension scheme
	local dc_year_start = 1997

//	DC annuity conversion parameters
//	At retirement the accumulated balance (iacc) is divided by an annuity factor
//	to produce a monthly pension. The annuity factor is computed per-person from
//	the real discount rate and the worker's remaining life expectancy at the
//	moment of retirement.
// 	local dc_annuity_rate     = 0.035	// Real discount rate used in annuity factor formula
// 	local dc_annuity_indexed  = 0		// 1 = index DC pension post-retirement; 0 = fixed nominal
//
//	
	

	
	
	
*quietly{	
********************************************************************************


// STEP 0.1 - Detect pre-sampling
//	If the input data was already sampled externally (e.g. synthetic data built at 1%),
//	a [weight] variable with values > 1 will exist in the baseyear file. In that case:
//	    - skip the sample command in Step 2 and the pensioner load to avoid double-sampling
//	    - override samplesize so that new affiliates (Step 1.1) receive the matching weight
//	If weight does not exist or equals 1, proceed with the default sample + generate weight logic

	//	Load the baseyear data into memory
	cd "`indir'"
	use "`baseyear_data'", clear
	tempfile baseyear_database
	save `baseyear_database', replace	

	// Check to see if the data is presampled
	local presampled = 0
	capture confirm variable weight
	if _rc == 0 {
		summarize weight, meanonly
		if r(mean) > 1 {
			local presampled = 1
			local samplesize = 100 / r(mean)	// infer implied sampling rate from weight
		} // end if r(mean) loop
	} // end if _rc
	noisily display "Pre-sampling detected: `presampled'  |  Effective samplesize: `samplesize'"

********************************************************************************
//	STEP 1.0
//	Load the population projections into memory	
	// Open the population projections
	cd "`popdir'"
	import delimited "`population_data'", clear
	
	// Reshape to long
 	greshape long y, i(iso3 location variable age sex) j(year) // gtools version of reshape [faster]
	rename y pop
	replace pop = 1000 * pop
	
	// Generate a gender variables
	capture drop gender
	generate gender = .
	replace  gender = 1 if sex == "male"
	replace  gender = 2 if sex == "female"
	
	// Generate working age population
	generate working_age = 0
	replace  working_age = pop if age >= `working_age_min' & age <= `working_age_max'

	
	// Save the population data
	tempfile population_database
	save `population_database', replace
	quietly summarize year, meanonly
	local population_max_year = r(max)	// Last year with population data (for capping)
	

	***************
	// Extend the population data beyond the source horizon
	// Note: Extrapolate using the most recently observed year-on-year growth
	//       rate, by age and gender, so the age structure is preserved
	if `endyear' > `population_max_year' {

		local population_prior_year = `population_max_year' - 1

		preserve
			// Growth rate of the last observed year, by age/gender cell
			keep if inrange(year, `population_prior_year', `population_max_year')
			keep iso3 location variable age sex gender year pop working_age
			reshape wide pop working_age, i(iso3 location variable age sex gender) j(year)

			rename pop`population_max_year'          pop_last
			rename pop`population_prior_year'        pop_prior
			rename working_age`population_max_year'   wa_last
			rename working_age`population_prior_year' wa_prior

			// Guard against missing/zero bases (e.g. very old/young ages)
			generate pop_growth = (pop_last / pop_prior) - 1 if pop_prior > 0
			generate wa_growth  = (wa_last  / wa_prior)  - 1 if wa_prior  > 0
			replace  pop_growth = 0 if missing(pop_growth)
			replace  wa_growth  = 0 if missing(wa_growth)

			keep iso3 location variable age sex gender pop_last wa_last pop_growth wa_growth
			tempfile pop_growth_rates
			save `pop_growth_rates', replace
		restore

		preserve
			// Compound that growth rate forward for every missing projection year
			use `pop_growth_rates', clear
			expand (`endyear' - `population_max_year')
			bysort iso3 location variable age sex gender: generate _step = _n
			generate year = `population_max_year' + _step

			generate pop         = pop_last * (1 + pop_growth)^_step
			generate working_age = wa_last  * (1 + wa_growth)^_step

			keep iso3 location variable age sex gender year pop working_age
			tempfile population_extended
			save `population_extended', replace
		restore

		append using `population_extended'

		// Re-save with the extended years included, and update the cap
		// so downstream code (e.g. the new-affiliate loop) stops truncating
		save `population_database', replace
		local population_max_year = `endyear'
	} //  end if `endyear' > `population_max_year'
	
	

	***************
	// Collapse the data to get population totals
	collapse (sum) pop working_age, by(iso3 location variable year gender sex)
	
	// Save the population data -  by gender
	tempfile population_db_gender
	save `population_db_gender', replace
	
	// Collapse the data to get population totals
	collapse (sum) pop working_age, by(iso3 location variable year)
	
	// Save the population data -  by total
	tempfile population_db_total
	save `population_db_total', replace

********************************************************************************
//	STEP 1.1
//	Build the new affiliate database
// 	Note: Affiliates are generated RANDOMLY (stochastic process)

	// Import and save the affilation data
	cd "`affdir'"
	import delimited "`affiliation_data'", clear
	tempfile affiliation_rate
	save `affiliation_rate', replace

	// Open the population projections
	use `population_database', clear
	
	// Merge in the affiliation rates
	join affiliation_rate, from(`affiliation_rate') by(age gender) keep(1 3) nogenerate	// ftools version of merge [faster]
	replace affiliation_rate = 0 if missing(affiliation_rate) // Rates for the young and old are likely not provided
	
	// Compute the affiliation rate (note: population is reported in units)
	generate new_affiliates = round(affiliation_rate * pop, 1)
	keep if new_affiliates > 0
	
	// Save the joined affiliate database
	tempfile affiliates_compact
	save `affiliates_compact', replace	
	
	
	// Generate a new database of affiliates for each year (to be appended later on)
	// Note: When projection year exceeds population data, reuse the last available year's rates
	forvalues yr = `baseyear'/`endyear' {
		// load only the small slice of affiliates that we need
		local yr_cap = min(`yr', `population_max_year')
		use `affiliates_compact', clear   
		keep if year == `yr_cap'
		
		// Restore the actual projection year label
		replace year = `yr'		
		
		// Expand the dataset
		expand new_affiliates
		
		// Only take a sample the of affiliates [TODO: Consider a stratified sample]
		sample `samplesize'

		// Generate a sampling weight [TODO: Change if we take a stratified sample]
		generate weight = 100 / `samplesize'
		
		// Determine the person's starting deciles
		// Assign wage decile randomly
		generate wage_decile = runiformint(1, 10)
		// Assign wage decile (within age and sex) to align with wage_decile
		generate wage_decile_age_sex = wage_decile
			
		// Cleanup
		keep age sex gender year wage_decile wage_decile_age_sex weight

		// Save the dataset
		tempfile affiliates`yr'
		save `affiliates`yr'', replace
		display "Generated `affiliates`yr''"
		} // end forvalues yr
		
	
********************************************************************************
//	STEP 1.2
//	Load the wage growth projections into memory
	cd "`wagegrowdir'"
	import delimited "`wage_grow_data'", clear
	rename year year_merge
	tempfile wage_growth_database
	save `wage_growth_database', replace
	quietly summarize year_merge, meanonly
	local wage_growth_max_year = r(max)		// Last year with wage growth data (for capping)
	
	

********************************************************************************
//	STEP 1.3
//	Load the pensioners database into memory
	cd "`indir'"
	use "`pensioners_data'", clear
	tempfile pensioners_database
	save `pensioners_database', replace	

// 	Pension type 
//	Note: This is very Mexico specific
// 	B = Old-age DB 
// 	C = Disability DB
// 	D = Survivor DB
// 	E = Old-age DC
// 	F = Disability DC
// 	G = Survivor DC


********************************************************************************
//	STEP 1.4
	//	Load the mortality rates database into memory
	cd "`mortdir'"
	import delimited "`mortality_data'", clear
	
	// Reshape to long
	greshape long y, i(iso3 location variable age sex) j(year_merge) // gtools version of reshape [faster]
	rename y mortality
	
	// Generate a gender variables
	capture drop gender
	generate gender = .
	replace  gender = 1 if inlist(sex, "male", "Male")
	replace  gender = 2 if inlist(sex, "female", "Female")
	drop sex
	
	//	Save the mortalty data
	tempfile mortality_database
	save `mortality_database', replace
	quietly summarize year, meanonly
	local mortality_max_year = r(max)		// Last year with mortality data (for capping)
	
	
	
	
********************************************************************************
//	STEP 1.5
	//	Load the life expectancy rates database into memory
	cd "`lifedir'"
	import delimited "`life_expect_data'", clear
	
	// Reshape to long
	greshape long y, i(iso3 country variable age sex) j(year_merge) // gtools version of reshape [faster]
	rename y life_expectancy
	
	// Generate a gender variables
	capture drop gender
	generate gender = .
	replace  gender = 1 if inlist(sex, "male", "Male")
	replace  gender = 2 if inlist(sex, "female", "Female")
	drop sex
	

	
	//	Save the mortalty data
	tempfile life_expect_database
	save `life_expect_database', replace
	quietly summarize year, meanonly
	local lifeexpect_max_year = r(max)		// Last year with life expectancy data (for capping)
	
	
	



********************************************************************************
//	STEP 1.6
//	Load the labour market assumptions into memory
	cd "`indir'"
	import delimited "`lm_assumptions'", clear
	tempfile labor_market_assumptions_data
	save `labor_market_assumptions_data', replace
	
//	Save the annual data as locals
//	When data is unavailable beyond its last year, carry forward the last known value
	local turnover_last = .
	local emp_rate_last = .
	forvalues yr = `startyear'/`endyear' {
		quietly summarize turnover_target if year == `yr'
		if r(N) > 0 {
			local turnover_`yr' = r(mean)
			local turnover_last  = r(mean)
		}
		else {
			local turnover_`yr' = `turnover_last'
		}
		quietly summarize emp_rate_growth if year == `yr'
		if r(N) > 0 {
			local emp_rate_`yr' = r(mean)
			local emp_rate_last  = r(mean)
		}
		else {
			local emp_rate_`yr' = `emp_rate_last'
		}
		}

	
********************************************************************************
//	STEP 1.7
//	Load the labour market assumptions into memory
	cd "`transdir'"
	
	// Load the job entry probabilities into memory
	estimates use "`job_exit_model'"
	estimates store job_exit_stored
	
	// Load the job exit probabilities into memory
	estimates use "`job_entry_model'"
	estimates store job_entry_stored
	
	
********************************************************************************
//	STEP 1.8
//	Load the lifecycle wage growth rates into memory
	cd "`lifecycledir'"
	estimates use "`lifecycle_model'"
	estimates store lifecycle_stored
	
	
********************************************************************************
//	STEP 1.9
//	Load the indexation assumptions into memory
	cd "`indir'"
	import delimited "`index_assummptions'", clear
	rename year year_merge
	tempfile indexation_database
	save `indexation_database', replace
	quietly summarize year_merge, meanonly
	local indexation_max_year = r(max)		// Last year with indexation data (for capping)
	
	
********************************************************************************
//	STEP 1.10
//	Create empty reporting files (for filling with data)
	
	
	**********
	// Reporting: make tempfile for inyear affiliate  - TOTALS
	tempfile inyear_affiliate_reporting_tot
	preserve
		clear
		save `inyear_affiliate_reporting_tot', emptyok replace
	restore
	
	**********
	// Reporting: make tempfile for inyear affiliate reporting - BREAKDOWNS
	tempfile inyear_affiliate_reporting
	preserve
		clear
		save `inyear_affiliate_reporting', emptyok replace
	restore

	
	
	**********
	// Reporting: make tempfile for inyear pension reporting - TOTALS
	tempfile inyear_pension_reporting_tot
	preserve
		clear
		save `inyear_pension_reporting_tot', emptyok replace
	restore
	
	**********
	// Reporting: make tempfile for inyear pension reporting - BREAKDOWNS
	tempfile inyear_pension_reporting
	preserve
		clear
		save `inyear_pension_reporting', emptyok replace
	restore
	




********************************************************************************
//	STEP 1.11
//	Load DC contribution parameters into memory
//
//	One Excel workbook is imported once before the main loop.
//	All rates are pre-stored as year- and bracket-indexed locals to avoid
//	repeated file reads inside the projection loop.


	********************
	// 	Import any Wage Units
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("wage_units") firstrow clear
	tempfile dc_wageunits_db
	save `dc_wageunits_db', replace
	
	
	********************
	//	Core policy parameters
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("policy") firstrow clear
	
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_policy_max_year = r(max)
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(dc_policy_yrs)
	foreach dc_yr of local dc_policy_yrs {
		// Save each monthly income threshold as a local
		foreach v in retage_male retage_female 				///
					 retage_early_male retage_early_female 	///
					 min_service_req  {
			quietly summarize `v' if year == `dc_yr', meanonly
			local dc_`v'_`dc_yr' = r(mean)
			di "Variable `v' for year `dc_yr': ``v'_`dc_yr''"
		} // end foreach v
	} // end foreach dc_yr
	

	********************
	//	Minimum pension parameters
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("min_pension") firstrow clear
	
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_minpen_max_year = r(max)

	// Save each monthly income threshold as a local
	quietly levelsof year, local(dc_minpen_yrs)
	foreach dc_yr of local dc_minpen_yrs {
		foreach v in minpen_base minpen_refwage minpen_adj1 minpen_adj2 					///
				 minpen_age minpen_age_max minpen_age_step minpen_age_lvl minpen_age_pct 	///
				 minpen_yos minpen_yos_max minpen_yos_step minpen_yos_lvl minpen_yos_pct 	///
				 minpen_wage_step minpen_wage_lvl minpen_wage_pct  {
			quietly summarize `v' if year == `dc_yr', meanonly
			local dc_`v'_`dc_yr' = r(mean)
			di "Variable `v' for year `dc_yr': ``v'_`dc_yr''"
		} // end foreach v
	} // end foreach dc_yr
	

	********************
	//	Maximum pension parameters
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("max_pension") firstrow clear
	
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_maxpen_max_year = r(max)
	
	// Save each monthly income threshold as a local
	quietly levelsof year, local(dc_minpen_yrs)
	foreach dc_yr of local dc_minpen_yrs {
		foreach v in  pension_max maxpen_age_threshold maxpen_age_scale ///
					  maxpen_yos_threshold maxpen_yos_scale {
			quietly summarize `v' if year == `dc_yr', meanonly
			local dc_`v'_`dc_yr' = r(mean)
			di "Variable `v' for year `dc_yr': ``v'_`dc_yr''"
		} // end foreach v
	} // end foreach dc_yr



	********************
	// 	Flat proportional contribution rates and reference values 
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("contributions") firstrow clear

	
	// Merge in the wage units
	merge m:1 year wage_unit_symbol using `dc_wageunits_db', keep(1 3) nogenerate
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"
	
	// Compute the minimum and maximum covered wage thresholds in monthly local currency units
	generate min_covered = wage_unit_value * covered_wage_floor
	generate max_covered = wage_unit_value * covered_wage_ceiling

	// Save as a tempfile
	tempfile dc_contributions_db
	save `dc_contributions_db', replace
	
	// Save the policy parameters for each year as locals
	quietly summarize year, meanonly
	local dc_contributions_max_year = r(max)
	quietly levelsof year, local(dc_yrs)
	foreach dc_yr of local dc_yrs {
		foreach v in employee_rate employer_rate selfemployed_rate ///
		             government_rate min_covered max_covered {
			quietly summarize `v' if year == `dc_yr', meanonly
			local dc_`v'_`dc_yr' = r(mean)
			di "Variable `v' for year `dc_yr': `dc_`v'_`dc_yr''"
		} // end foreach v 
	} // end foreach dc_yr


	********************
	// 	Employer pension contribution rates by income bracket and year 
	//	Brackets are pre-stored with their wage thresholds
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("employer") firstrow clear
	
	// Merge in the wage units
	merge m:1 year wage_unit_symbol using `dc_wageunits_db', keep(1 3) nogenerate
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"
	
	// Compute bracket thresholds in monthly local currency units
	generate thresh = wage_unit_value * wage_upper
	
	// Minor cleanup
	rename employer_rate rate
	
	// Save as a tempfile
	tempfile dc_employer_db
	save `dc_employer_db', replace

	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_employer_max_year = r(max)
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(dc_employer_yrs)
	foreach dc_yr of local dc_employer_yrs {
		// Get the number of brackets
		quietly summarize bracket if year == `dc_yr', meanonly
		local dc_employer_nbrackets_`dc_yr' = r(max)
		// Save each monthly income threshold as a local
		forvalues b = 1/`dc_employer_nbrackets_`dc_yr'' {
			foreach v in thresh rate {
				quietly summarize `v' if year == `dc_yr' & bracket == `b', meanonly
				local dc_employer_`v'_`b'_`dc_yr' = r(mean)
				di "Variable `v' for year `dc_yr' and bracket `b': `dc_employer_`v'_`b'_`dc_yr''"
			} // end foreach v
		} // end forvalues b
	} // end foreach dc_yr 

	
	********************
	// Government social security subsidies (if any) 
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("government_subsidy") firstrow clear
	
	// Merge in the wage units
	merge m:1 year wage_unit_symbol using `dc_wageunits_db', keep(1 3) nogenerate
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"
	
	// Convert subsidies to monthly values
	replace subsidy_lcu = subsidy_lcu * 30.4 if frequency == "daily"
	replace subsidy_lcu = subsidy_lcu / 12   if frequency == "annual"	

	// Compute bracket thresholds in monthly local currency units
	generate thresh = wage_unit_value * wage_upper
	
	// Minor cleanup
	rename subsidy_lcu subsidy
	
	// Save as a tempfile	
	tempfile dc_government_db
	save `dc_government_db', replace
	
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_gov_max_year = r(max)
	di "Max year: `dc_gov_max_year'"
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(dc_gov_yrs)
	foreach dc_yr of local dc_gov_yrs {
		// Get the number of brackets
		quietly summarize bracket if year == `dc_yr', meanonly
		local dc_gov_nbrackets_`dc_yr' = r(max)
		// Save each monthly income threshold as a local
		forvalues b = 1/`dc_gov_nbrackets_`dc_yr'' {
			foreach v in thresh subsidy {
				quietly summarize `v' if year == `dc_yr' & bracket == `b', meanonly
				local dc_gov_`v'_`b'_`dc_yr' = r(mean)
				di "Variable `v' for year `dc_yr' and bracket `b': `dc_gov_`v'_`b'_`dc_yr''"
			} // end foreach v
		} // end forvalue b
	} // end foreach dc_yr



	********************
	//  Employee pension contribution rates by income bracket and year 
	//	Brackets are pre-stored with their wage thresholds
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("employee") firstrow clear
	
	// Merge in the wage units
	merge m:1 year wage_unit_symbol using `dc_wageunits_db', keep(1 3) nogenerate
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"
	
	// Compute bracket thresholds in monthly local currency units
	generate thresh = wage_unit_value * wage_upper
	
	// Minor cleanup
	rename employee_rate rate
	
	// Save as a tempfile
	tempfile dc_employee_db
	save `dc_employee_db', replace

	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_employee_max_year = r(max)
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(dc_employee_yrs)
	foreach dc_yr of local dc_employee_yrs {
		// Get the number of brackets
		quietly summarize bracket if year == `dc_yr', meanonly
		local dc_employee_nbrackets_`dc_yr' = r(max)
		// Save each monthly income threshold as a local
		forvalues b = 1/`dc_employee_nbrackets_`dc_yr'' {
			foreach v in thresh rate {
				quietly summarize `v' if year == `dc_yr' & bracket == `b', meanonly
				local dc_employee_`v'_`b'_`dc_yr' = r(mean)
				di "Variable `v' for year `dc_yr' and bracket `b': `dc_employee_`v'_`b'_`dc_yr''"
			} // end foreach v
		} // end forvalues b
	} // end foreach dc_yr 
	
	
	********************
	// 	Self-employed pension contribution rates by income bracket and year 
	//	Brackets are pre-stored with their wage thresholds
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("self_employed") firstrow clear
	
	// Merge in the wage units
	merge m:1 year wage_unit_symbol using `dc_wageunits_db', keep(1 3) nogenerate
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"
	
	// Compute bracket thresholds in monthly local currency units
	generate thresh = wage_unit_value * wage_upper
	
	// Minor cleanup
	rename selfemp_rate rate
	
	// Save as a tempfile
	tempfile dc_selfemp_db
	save `dc_selfemp_db', replace

	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_selfemp_max_year = r(max)
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(dc_selfemp_yrs)
	foreach dc_yr of local dc_selfemp_yrs {
		// Get the number of brackets
		quietly summarize bracket if year == `dc_yr', meanonly
		local dc_selfemp_nbrackets_`dc_yr' = r(max)
		// Save each monthly income threshold as a local
		forvalues b = 1/`dc_selfemp_nbrackets_`dc_yr'' {
			foreach v in thresh rate {
				quietly summarize `v' if year == `dc_yr' & bracket == `b', meanonly
				local dc_selfemp_`v'_`b'_`dc_yr' = r(mean)
				di "Variable `v' for year `dc_yr' and bracket `b': `dc_selfemp_`v'_`b'_`dc_yr''"
			} // end foreach v
		} // end forvalues b
	} // end foreach dc_yr 
	
	
	********************
	// 	Fund fees and performance assumptions [varies by year]
	cd "`indir'"
	import excel using "`dc_parameters_data'", sheet("performance") firstrow clear
	
	//	Convert wage units to monthly values
	replace dc_fees_flat = dc_fees_flat * 30.4 if fees_frequency == "daily"
	replace dc_fees_flat = dc_fees_flat / 12   if fees_frequency == "annual"

	
	// Save as a tempfile
	tempfile dc_performance_db
	save `dc_performance_db', replace

	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local dc_performance_max_year = r(max)
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(dc_performance_yrs)
	foreach dc_yr of local dc_performance_yrs {
		// Save each monthly income threshold as a local
		foreach v in dc_return_gross dc_fees_mer dc_fees_flat ///
					 dc_annuity_rate dc_annuity_indexed {
			quietly summarize `v' if year == `dc_yr', meanonly
			local `v'_`dc_yr' = r(mean)
			di "Variable `v' for year `dc_yr': ``v'_`dc_yr''"
		} // end foreach v
	} // end foreach dc_yr 
	

	
	
	
	


********************************************************************************
//	STEP 1.12
//	Load DB policy parameters into memory
//
//	One Excel workbook (`db_parameters_data') is imported once before the main loop.
//	All policy parameters are pre-stored as year-indexed locals so that Stage 8
//	and the annual loop can resolve time-varying values without repeated file reads.
//
//	Six sheets:
//	  policy      - core benefit formula parameters (retirement ages, accrual, etc.)
//	  accrual     - accrual rate policy, varying by wage (ir applicable)
//	  min_pension - minimum pension floor and scaling parameters
//	  max_pension - maximum pension floor and scaling parameters
//	  indexation  - post-retirement and MPI indexation coefficients (alpha, revalor)
//	  wage_units  - Description of any wage units used (by year)
//
//	Carry-forward rule: years beyond the last data row use that row's values.
//	Add a new row to model a policy reform without changing any Stata code.



	********************
	// 	Import any Wage Units
	cd "`indir'"
	import excel using "`db_parameters_data'", sheet("wage_units") firstrow clear
	tempfile db_wageunits_db
	save `db_wageunits_db', replace
	

	********************
	// Core policy parameters
	cd "`indir'"
	import excel using "`db_parameters_data'", sheet("policy") firstrow clear
	
	
	**********
	// Merge in the wage units for covered wage
	rename covered_wage_unit_symbol wage_unit_symbol
	merge m:1 year wage_unit_symbol using `db_wageunits_db', keep(1 3) nogenerate
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"
	
	// Compute the minimum and maximum covered wage thresholds in monthly local currency units
	generate min_covered = wage_unit_value * covered_wage_floor
	generate max_covered = wage_unit_value * covered_wage_ceiling
	
	**********
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local db_policy_max_year = r(max)
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(db_policy_yrs)
	foreach db_yr of local db_policy_yrs {
		// Save each monthly income threshold as a local
		foreach v in retage_male retage_female 								 ///
					 retage_early_male retage_early_female					 /// 
					 lumpsum_flag lumpsum_interest_rate 				 	 ///
					 discount_rate contribution_rate_ee contribution_rate_er ///
					 min_covered max_covered {
			quietly summarize `v' if year == `db_yr', meanonly
			local db_`v'_`db_yr' = r(mean)
			di "Variable `v' for year `db_yr': ``v'_`db_yr''"
		} // end foreach v
	} // end foreach db_yr
	
	
	********************
	// Accrual rate policy parameters
	cd "`indir'"
	import excel using "`db_parameters_data'", sheet("accrual") firstrow clear
	
	
	
	**********
	// Merge in the wage units for reference wage
	rename ref_wage_unit_symbol wage_unit_symbol
	merge m:1 year wage_unit_symbol using `db_wageunits_db', keep(1 3) nogenerate
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"

	
	// Compute the minimum and maximum covered wage thresholds in monthly local currency units
	generate thresh = wage_unit_value * ref_wage_upper
	
	**********
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local db_policy_max_year = r(max)
	
	// Save the policy parameters for each year as locals
	quietly levelsof year, local(db_policy_yrs)
	foreach db_yr of local db_policy_yrs {
		// Get the number of brackets
		quietly summarize bracket if year == `db_yr', meanonly
		local db_policy_nbrackets_`db_yr' = r(max)
		// Save each monthly income threshold as a local
		forvalues b = 1/`db_policy_nbrackets_`db_yr'' {
			foreach v in min_service_req accrual_rate accrual_max ///
						 standard_rate early_penalty late_bonus thresh {
				quietly summarize `v' if year == `db_yr' & bracket == `b', meanonly
				local db_`v'_`b'_`db_yr' = r(mean)
				di "Variable `v' for year `db_yr' and bracket `b': `db_`v'_`b'_`dc_yr''"
			} // end foreach v
		} // end forvalues b	
	} // end foreach db_yr
	
	

	********************
	// Minimum pension parameters
	cd "`indir'"
	import excel using "`db_parameters_data'", sheet("min_pension") firstrow clear
	
	**********
	// Merge in the wage units for minpen_base_unit wage
	rename minpen_base_unit wage_unit_symbol
	merge m:1 year wage_unit_symbol using `db_wageunits_db', keep(1 3) nogenerate
	
	//[TODO: Make adjustments for wage units - also double check that minpen in the DC also has the adjustments]
	
	//	Convert wage units to monthly values
	replace wage_unit_value = wage_unit_value * 30.4 if wage_unit_freq == "daily"
	replace wage_unit_value = wage_unit_value / 12   if wage_unit_freq == "annual"
	
	// Update the minimum pension
	replace minpen_base = wage_unit_value * minpen_base
	
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local db_minpen_max_year = r(max)

	// Save each monthly income threshold as a local
	quietly levelsof year, local(db_minpen_yrs)
	foreach db_yr of local db_minpen_yrs {
		foreach v in minpen_base minpen_refwage minpen_adj1 minpen_adj2 					///
				 minpen_age minpen_age_max minpen_age_step minpen_age_lvl minpen_age_pct 	///
				 minpen_yos minpen_yos_max minpen_yos_step minpen_yos_lvl minpen_yos_pct 	///
				 minpen_wage_step minpen_wage_lvl minpen_wage_pct  {
			quietly summarize `v' if year == `db_yr', meanonly
			local db_`v'_`db_yr' = r(mean)
			di "Variable `v' for year `db_yr': ``v'_`db_yr''"
		} // end foreach v
	} // end foreach db_yr
	

	********************
	//	Maximum pension parameters
	cd "`indir'"
	import excel using "`db_parameters_data'", sheet("max_pension") firstrow clear
	
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local db_maxpen_max_year = r(max)
	
	// Save each monthly income threshold as a local
	quietly levelsof year, local(db_maxpen_yrs)
	foreach db_yr of local db_maxpen_yrs {
		foreach v in  pension_max maxpen_age_threshold maxpen_age_scale ///
					  maxpen_yos_threshold maxpen_yos_scale {
			quietly summarize `v' if year == `db_yr', meanonly
			local db_`v'_`db_yr' = r(mean)
			di "Variable `v' for year `db_yr': ``v'_`db_yr''"
		} // end foreach v
	} // end foreach db_yr
	

	********************
	//	Indexation and revalorization coefficients
	cd "`indir'"
	import excel using "`db_parameters_data'", sheet("indexation") firstrow clear
	
	// Determine the latest year of policy parameters
	quietly summarize year, meanonly
	local db_index_max_year = r(max)
	
	// Save each monthly income threshold as a local
	quietly levelsof year, local(db_index_yrs)
	foreach db_yr of local db_index_yrs {
		foreach v in alpha1 alpha2 alpha3 												///
				 revalor_inflation_coeff revalor_realwage_coeff revalor_anchor_coeff 	///
				 mpi_inflation_coeff mpi_realwage_coeff mpi_anchor_coeff {
			quietly summarize `v' if year == `db_yr', meanonly
			local db_`v'_`db_yr' = r(mean)
			di "Variable `v' for year `db_yr': ``v'_`db_yr''"
		} // end foreach v
	} // end foreach db_yr

********************************************************************************
// 	STEP 2
// 	Set-up the baseyear database
// 	Expected variables:
	// 	age 
	// 	gender 
	// 	id 
	// 	pension_class 
	// 	yob 
	// 	wage 
	// 	dens 
	// 	year
	// 	month 
	// 	loa 
	// 	los 
	// 	iacc 
	// 	spell_length 
	// 	wage_decile_ref 
	// 	wage_decile 
	// 	wage_decile_age_sex 
	// 	status 
	// 	weight
	// reference_wage	= most recent wage (placeholder to pension refernece wages)

//	Project the database
//	Open the baseyear microdata
	use "`baseyear_database'", clear

	
	**********
	// 	We need to sample people, but they have multiple observations in the base dataset
	//	[TODO: Consider a stratified sample]
	//	Skip if the synthetic data was already sampled externally (presampled == 1):
	//	in that case weight already exists with the correct value and re-sampling would be wrong.
	if `presampled' == 0 {
		preserve
			tempfile sample_merge
			keep id
			duplicates drop
			sample `samplesize'
			generate sampled = 1
			save `sample_merge'
		restore

		//	Merge the sample back into the dataset to determine who to keep
		join sampled, from(`sample_merge') by(id) keep(1 3) nogenerate // ftools version of merge [faster]
		keep if sampled == 1
		drop sampled

		// Generate a sampling weight [TODO: Change if we take a stratified sample]
		generate weight = 100 / `samplesize'
	} // end if presampled == 0
	// If pre-sampled: weight already exists in the data with the correct value; nothing to do.

	
	
	**********
	//	Grow the last year of the affiliate database to the base year
	replace year = `baseyear'
	replace wage = wage * `wage_adjustment'
	// Guard: sparse age-gender cells in the 00 file can produce missing iacc
	// for non-contributors (0 * missing_scale = missing). Correct to zero.
	replace iacc = 0 if missing(iacc)
	

	
	
	
	
	**********
	//	Define some reporting variables
	generate new_affiliate_flag   = .			// Flag for new affiliates
	generate deathyear  		  = .			// Year person died
	generate wage_at_death 		  = .			// Person's wage at death
	generate contribution_density = los / loa	// Contribution density
	generate birthmonth = runiformint(1, 12)	// Month someone was born (randomly assigned)
	generate deathmonth = runiformint(1, 12) 	// Month person died (randomly assigned)
	

	**********
	// 	Compute the density decile for each person
	//	This represents a person's permanent propensity to be an active contributor
	xtile density_decile = contribution_density, nq(10)
	
	// Step 2: Build conditional CDF — P(density_decile_ref <= d | wage_decile_ref = w)
	//         Stored as 100 locals (cdf_w_d); used in Part B to sample new affiliates
	preserve
		keep if status == 1 & !missing(density_decile) & !missing(wage_decile_ref)
		gcollapse (count) n = density_decile, by(wage_decile_ref density_decile)
		gegen n_wage = sum(n), by(wage_decile_ref)
		generate prop = n / n_wage
		bysort wage_decile_ref (density_decile): generate cum_prop = sum(prop)

		forvalues w = 1/10 {
			local prev = 0
			forvalues d = 1/10 {
				quietly summarize cum_prop ///
					if wage_decile_ref == `w' & density_decile == `d'
				if r(N) > 0 {
					local cdf_`w'_`d' = r(mean)
					local prev         = `cdf_`w'_`d''
				}
				else {
					local cdf_`w'_`d' = `prev'    // carry forward if cell is empty
				}
			}
			local cdf_`w'_10 = 1    // guarantee CDF reaches 1
		}
	restore
		
 
	**********
	// [Sanity check: Output histograms of contribution density by decile]
	// Save histogram to compare with simulated density in the last year
	if `histograms' == 1 {
		histogram contribution_density if month == 12, name(cod_baseyear, replace) yscale(range(0 5))
		histogram contribution_density if month == 12, by(wage_decile) name(cod_by_decile_baseyear, replace) yscale(range(0 15))
		} // end if histograms
	
	**********
	// Placeholder: Affiliate's pension reference wage (starts as their wage)
	// Note: We now read in reference wage from longitudinal data because we need values for people who did not work in the base year
	
	//	Placeholder: The N best years of earnings
	// 	2 = Best N years in the career: Highest N wages in the career
	if `ref_wage_type' == 2   {
		forvalues i = 1/`ref_wage_n' {
			generate bestwage`i' = 0
			} // end forvalues i
		} // end if `ref_wage_type' == 2 
		
	//	Placeholder: The N best years of earnings and the year of the best wage
	// 	3 = Best N years within the last M years: Highest N wages within last M years before retirement
	if  `ref_wage_type' == 3  {
		forvalues i = 1/`ref_wage_n' {
			generate bestwage`i' = 0
			generate bestyear`i' = 0
			} // end forvalues i
		} // end if `ref_wage_type' == 3
		
			
	
	**********
	// Placeholder: Variables for determining transition rates
	generate age_gap 		= .			// Years until eligible for pension (on basis of age)
	generate los_gap 		= .			// Years until eligible for pension (on basis of service)
	generate no_hope 		= .			// Indicator: person has no hope of being eligible for a pension
	generate retirement_age = .			//	Determine the earliest age at which people can retirement
	generate pension_gap 	= .			// Years until eligible for pension (on basis of service or age, whichever is binding)
	generate implied_retage = .			// Implied age that person would be eligible for retirement (if fully contributing)
	generate group 			= .			// Merging group (1 = age constrainted, 2 = service constrained, 3 = no hope)
	generate age_merge 		= .			// For merging to transitions database (that has 3 groups in it) 
	generate service_gap 	= .			// For merging to transitions database (that has 3 groups in it) 
	generate exiter 		= .			// Flag: 1 = exiting formal work
	generate reentrant 		= .			// Flag: 1 = reentering formal work
	generate new_affiliate 	= .			// Flag: 1 = entering formal work for the first time


	

	**********
	// Placeholder: Wage distribution variables
	generate age_grp		  = floor(age / 5) * 5 	// 5-year age grouping
	generate age_grp_capped   = min(age_grp, `wage_stats_max_age_grp') // Age grouping, capped for older workers (where data is thin)
	generate wage_mean_decile = .					// Mean by decile
	generate wage_sd_decile   = .					// Standard deviation by decile
	generate wage_min_decile  = . 					// Minimum by decile
	generate wage_max_decile  = .					// Maximum by decile
	generate wage_change	  = .					// Flag: 1 = wage changed that period (for workers)
	generate wage_ref		  = reference_wage		// Reference wage for those that lost their job (model assumed they come back to the same wage) 
	generate sim_wage_growth  = .					// Simulated wage_growth after adjusting for relative growth (age-sex-decile) 
	generate average_wage     = .					// Economy-wide average wage
	
	
	**********
	//	Placeholders: Pension eligibilty [current year]
	generate db_pension_elig_mincont = 0		// Defined benefit - Eligible on the basis of contributions [current year]
	generate db_pension_elig_age     = 0		// Defined benefit - Eligible on the basis of age [current year]
	generate db_pension_elig_early   = 0 		// Defined benefit - Early retirement restirctions [current year]
	generate db_pension_elig		 = 0 		// Defined benefit - Overall eligibility [current year]
	
	generate db_pension_elig_mincont_next 	= 0		// Defined benefit - Eligible on the basis of contributions [expected, next year]
	generate db_pension_elig_age_next     	= 0		// Defined benefit - Eligible on the basis of age [expected, next year]
	generate db_pension_elig_early_next   	= 0 	// Defined benefit - Early retirement restirctions [expected, next year]
	generate db_pension_elig_next		 	= 0 	// Defined benefit - Overall eligibility [expected, next year]
	
	generate dc_pension_elig_mincont = 0 		// Defined contribution - Eligible on the basis of contributions
	generate dc_pension_elig_minpen	 = 0 		// Defined contribution - Eligible on the basis of achieving minimum pension amount
	generate dc_pension_elig_age	 = 0 		// Defined contribution - Eligible on the basis of age
	generate dc_pension_elig_early	 = 0 		// Defined contribution - Eligible based on early retirement rules
	generate dc_pension_elig		 = 0 		// Defined contribution - Overall eligibility
	
	generate start_year			  	 = floor(max(`yr' - (loa / 12), 0)) // Year first affilated with the pension system
	
	
	**********
	// Placeholder: DB Pension plan
	generate yos 					= .		// Length of service (in years) [current year]
	generate db_years_early 		= .		// Number of years before regular retirement age [current year]
	generate db_years_late 			= .		// Number of years after regular retirement age [current year]
	generate db_replacement_rate	= .		// Calculated pension replacement rate [current year]
	generate db_pension_benefit_base = .	// Monthly pension benefit (before applying minmax) [current year]
	generate db_pension_benefit		= .		// Monthly pension benefit [current year]
	generate db_annuity_factor		= .		// Annuity factor for DB pension plan [current year]
	
	generate db_accrual_rate 		= .		// Annual accrual rate
	generate db_standard_rate 		= .		// Total accrual rate with the minimum contribution period
	generate db_min_service_req 	= .		// Minimum service reqirement
	generate db_accrual_max 		= .		// Maximum accrual rate
	generate db_early_penalty		= .		// Annual penalty for retiring one year early
	generate db_late_bonus 			= .		// Annual bonus   for retiring one year late
	
	generate yos_next 						= .		// Length of service (in years) [expected, next year]
	generate db_years_early_next			= .		// Number of years before regular retirement age [expected, next year]
	generate db_years_late_next 			= .		// Number of years after regular retirement age [expected, next year]
	generate db_replacement_rate_next		= .		// Calculated pension replacement rate [expected, next year]
	generate db_pension_benefit_base_next 	= .		// Monthly pension benefit (before applying minmax) [expected, next year]
	generate db_pension_benefit_next		= .		// Monthly pension benefit [expected, next year]
	generate db_annuity_factor_next 		= .		// Annuity factor for DB pension plan when contributing for another year [expected, next year]

	
	generate db_covered_wage		= .		// Covered wage used for DB pension benefit calculations.
	generate db_gov_pension			= .		// Amount of any government subsidies to DB pensioners
	generate minpen_age_db			= .		// Age component of minimum pension amount
	generate minpen_yos_db 			= .		// Service length (years) component of minimum pension amount
	generate minpen_wage_db			= .		// Wage component of minimum pension amount
	generate db_pension_minpen		= . 	// Minimum pension amount
	generate db_pension_maxpen		= .		// Maximum pension amount
	generate pension_lumpsum		= .		// Lumpsum amount for those who retire with no pension eligibility
	generate retire_year			= .		// Year retired
	generate retire_month			= .		// Month retired
	
	
	**********
	// Placeholder: DC Pension plan
	generate dc_covered_wage 		= .		// Covered wage for DC pension plan
	generate employer_ssc_rate 		= .		// Effective employer pension contribution rate
	generate gov_subsidy 			= .		// Government subsidies
	generate government_ssc_rate 	= .		// Effective government pension contribution rate
	generate employee_ssc_rate 		= .		// Effective employee pension contribution rate
	generate dc_employer_ssc 		= .		// Employer pension contributions
	generate dc_employee_ssc 		= .		// Employee pension contributions
	generate dc_government_ssc 		= .		// Government pension contributions
	generate dc_total_contrib 		= .		// Total pension contributions
	generate dc_pension_benefit		= .		// Monthly DC pension annuity (set at retirement in Stage 9.5)
	generate dc_gov_pension			= .		// Amount of any government subsidies to DC pensioners
	generate minpen_age_dc			= .		// Age component of minimum pension amount
	generate minpen_yos_dc 			= .		// Service length (years) component of minimum pension amount
	generate minpen_wage_dc			= .		// Wage component of minimum pension amount
	generate dc_pension_minpen		= . 	// Minimum pension amount
	generate dc_pension_maxpen		= .		// Maximum pension amount
	generate dc_annuity_factor		= .		// Annuity factor for DC pension plan
	generate dc_annuity_factor_next = .		// Annuity factor for DC pension plan when contributing for another year
	generate dc_annuity				= .		// Current value of DC annuity
	
	
	**********
	// Placeholder: Retirement decision
	generate pension_wealth			= .		// Curently accumulated pension wealth
	generate pension_wealth_next	= .		// Expected accumulated pension welath next year
	generate benefit_now			= .		// Annual pension benefit if retiring now
	generate pension_accrual		= .		// Pension wealth Accrual = gain in pension wealth - foregone pension payment
	generate implicit_tax			= .		// Implicit tax rate (Gruber-Wise: normalised by annual earnings)
	generate pension_elig			= . 	// Eligible for a pension (DC or DB, depending on class)
	generate retire_on_tax			= .		// Decision rule for retiring (based on expected accrual of pension wealth)
	generate minimum_pension		= .		// Flag: person recieves minimum pension
	generate gets_lumpsum			= .		// Flag: Person gets a lumpsum pension and is not eligible
	
	
	**********
	// Placeholder: Growth rate merging and debugging
	generate age_m = min(age, `max_reliable_age')	// Topcode age at higher level of reliable support in lifecycle model
	generate debug_wage_growth_user = .	
	generate debug_db_revalorization_rate = .
	generate debug_mpi_rate = .

	
	
	**********
	// Update variables for determining labour market conditions
	
	// Merge in the labour market assumptions
	capture drop turnover_target
	capture drop emp_rate_growth
	join emp_rate_growth turnover_target, from(`labor_market_assumptions_data') by(year) keep(1 3) nogenerate	// ftools version of merge [faster]
	local turnover_target = turnover_target		// Easier to have these as locals than as variables [only works if we only have one year in the DB]
	local emp_rate_growth = emp_rate_growth		// Easier to have these as locals than as variables [only works if we only have one year in the DB]


	
	// Store the population and employment totals as well as the total flows
	tempvar samp
	tempvar emp
	tempvar reentrants
	tempvar affiliates
	tempvar new_affiliates
	tempvar exiters

	
	// Note: We use this method do that we can disaggregate results by gender-age-decile (if we want to)
	gegen `samp' 	  		= count(dens)  		  	// Sample population count
	gegen `emp'  	  		= sum(dens)    		   	// Employment count
	gegen `reentrants'  	= sum(reentrant)      	// Number of re-entrants
	gegen `affiliates'		= sum(status!=99)		// Number of total affilates
	gegen `new_affiliates'  = sum(new_affiliate)  	// Number of new affiliates
	gegen `exiters'  		= sum(exiter)  		  	// Number of exiters

	
	// This is mostly for reporting (and for adjusting transition rates)
	generate sample_pop 	 	= `samp' / 12						// Annual sample population count
	generate affiliates			= `affiliates' / 12					// Number of affilates
	generate employment      	= `emp'	/ 12						// Number of affiliates who are contributing ("working")
	generate employment_rate 	= 100 * employment / affiliates		// "Employment rate": Share of affiliates who are working
	generate unemployment    	= affiliates - employment			// Number of affiliates who are not contributing ("not working")
	generate reentrants      	= `reentrants'						// Number of re-entrants
	generate new_affiliates  	= `new_affiliates'					// Number of new affiliates
	generate exiters 		 	= `exiters'							// Number of exiters
	generate exits_target 	 	= (`turnover_target'/ 100) * affiliates / 2 // Target number of exists (assuming inflows match outflows)	
	generate reentrants_target 	= exits_target 						// Target number of re-entrants (assuming inflows match outflows)
	generate inflow_adjustment 	= 1									// Adjustment to ensure inflows match labour market assumptions (none in baseyear)
	generate outflow_adjustment = 1									// Adjustment to ensure outflows match labour market assumptions (none in baseyear)
	generate expected_reentrants = .
	generate expected_exits 	= .
	generate transition_in 		= .
	generate transition_out 	= .
	generate log_cod 			= log(max(contribution_density, 0.001))

	//	Store the baseline employment rate (for targeting)
	local target_emp_rate_last  = employment_rate / 100				// Baseline employment rate


	// Compute inflow and outflow rates
	// Note: We do not include new_affiliates in the inflow rate as they do not come from the stock of non-contributing affilates
	generate inflow_rate   = 100 * reentrants / unemployment 					// Share of "unemployed" flowing into "employment"
	generate outflow_rate  = 100 * exiters / employment							// Share of "employed" flowing into "unemployment"
	generate turnover_rate = 100 * (exiters + reentrants) / (affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
 

	*******************
	// Store the mean and sd of wages by decile, age and gender in the baseyear.
	// Then sample to give the wages to new entrants.
	// Note: Cells can be empty or have n=1 (sd undefined) -> fall back to
	//       coarser aggregation levels so no row ends up missing.
	
	// Cap the age band for wage stats: pool everyone >= retirement age into
	// one cell so old-age wage sampling isn't based on thin/empty support
	replace age_grp_capped = min(age_grp, `wage_stats_max_age_grp')
	
	// Collapse by decile gender and age group
	preserve
		gcollapse (mean) wage_mean_decile=wage (sd) wage_sd_decile=wage ///
				  (min)  wage_min_decile=wage  (max) wage_max_decile=wage ///
				  (count) wage_n_decile=wage ///
				  , by(wage_decile_ref gender age_grp_capped)
		tempfile stats_dga
		save `stats_dga', replace
	restore
	
	// Collapse by decile and age group
	preserve
		gcollapse (mean) wage_mean_da=wage (sd) wage_sd_da=wage ///
				  (min)  wage_min_da=wage  (max) wage_max_da=wage ///
				  (count) wage_n_da=wage ///
				  , by(wage_decile_ref age_grp_capped)
		tempfile stats_da
		save `stats_da', replace
	restore
	
	// Collapse by age group
	preserve
		gcollapse (mean) wage_mean_a=wage (sd) wage_sd_a=wage ///
				  (min)  wage_min_a=wage  (max) wage_max_a=wage ///
				  (count) wage_n_a=wage ///
				  , by(age_grp_capped)
		tempfile stats_a
		save `stats_a', replace
	restore
	
	// Combine all of the collapses together
	preserve
		use `stats_dga', clear
		join wage_mean_da wage_sd_da wage_min_da wage_max_da, from(`stats_da') by(wage_decile_ref age_grp_capped) nogenerate
		join wage_mean_a  wage_sd_a  wage_min_a  wage_max_a,  from(`stats_a')  by(age_grp_capped)                 nogenerate
		
		// Back-fill: coarser level covers (a) empty cells, and (b) sd undefined at n=1
		replace wage_mean_decile = wage_mean_da if missing(wage_mean_decile)
		replace wage_mean_decile = wage_mean_a  if missing(wage_mean_decile)
		replace wage_sd_decile   = wage_sd_da   if missing(wage_sd_decile) | wage_sd_decile == 0
		replace wage_sd_decile   = wage_sd_a    if missing(wage_sd_decile) | wage_sd_decile == 0
		replace wage_min_decile  = wage_min_da  if missing(wage_min_decile) | wage_min_decile == wage_mean_decile
		replace wage_min_decile  = wage_min_a   if missing(wage_min_decile) | wage_min_decile == wage_mean_decile
		replace wage_max_decile  = wage_max_da  if missing(wage_max_decile) | wage_max_decile == wage_mean_decile
		replace wage_max_decile  = wage_max_a   if missing(wage_max_decile) | wage_max_decile == wage_mean_decile

		drop wage_mean_da wage_sd_da wage_min_da wage_max_da ///
			 wage_mean_a  wage_sd_a  wage_min_a  wage_max_a  wage_n_decile
			 
		tempfile wage_stats
		save `wage_stats', replace
	restore
	
	
	// Drop old values and join the new ones back onto the full dataset
	capture drop wage_mean_decile wage_sd_decile wage_min_decile wage_max_decile
	join wage_mean_decile wage_sd_decile wage_min_decile wage_max_decile, from(`wage_stats') by(wage_decile_ref gender age_grp_capped) keep(1 3) nogenerate

	
	**********
	// Reporting: make tempfile for EXTENDED OUTPUT inyear affiliate reporting
	if `extended_output' == 1 {
		tempfile extended_output_data
		// Start by saving the baseyear
		save `extended_output_data', emptyok replace
		} // end if extedned _output





********************************************************************************
********************************************************************************
//	Project the database



	****************************************************************************
	****************************************************************************
	****************************************************************************
	****************************************************************************
	****************************************************************************
//	Affiliates: Loop over the projection period
	forvalues yr = `startyear'/`endyear' {
		
		// Save the last row of the dataset for later (when adding new ID numbers)
		local last_row = _N
		
		// Record the previous year
		local lastyear = `yr' - 1


		
		************************************************************************
		************************************************************************
		//	Stage 00 - Update DC policy parameters (with carry-forward to last available year)
		// 	Get the year of the most recent policy levels
		// 	Get the year of the most recent policy levels
		local yr_dc_policy = min(`yr', `dc_policy_max_year')

		//	Core policy parameters
		local dc_retage_male          = `dc_retage_male_`yr_dc_policy''
		local dc_retage_female        = `dc_retage_female_`yr_dc_policy''
		local dc_retage_early_male    = `dc_retage_early_male_`yr_dc_policy''
		local dc_retage_early_female  = `dc_retage_early_female_`yr_dc_policy''
		local dc_min_service_req      = `dc_min_service_req_`yr_dc_policy''
	
		//	Min/max pension: override from Excel when within data range;
		//	else keep the running value grown by MPI indexation at end of Stage 8.
		if `yr' <= `dc_minpen_max_year' | `yr' == `startyear' {
			local yr_dc_minpen           = min(`yr', `dc_minpen_max_year')
			local yr_dc_maxpen           = min(`yr', `dc_maxpen_max_year')
			
			// Minimum pension
			local dc_minpen_base          = `dc_minpen_base_`yr_dc_minpen''
			local dc_minpen_refwage       = `dc_minpen_refwage_`yr_dc_minpen''
			local dc_minpen_adj1          = `dc_minpen_adj1_`yr_dc_minpen''
			local dc_minpen_adj2          = `dc_minpen_adj2_`yr_dc_minpen''
			local dc_minpen_age           = `dc_minpen_age_`yr_dc_minpen''
			local dc_minpen_age_max       = `dc_minpen_age_max_`yr_dc_minpen''
			local dc_minpen_age_step      = `dc_minpen_age_step_`yr_dc_minpen''
			local dc_minpen_age_lvl       = `dc_minpen_age_lvl_`yr_dc_minpen''
			local dc_minpen_age_pct       = `dc_minpen_age_pct_`yr_dc_minpen''
			local dc_minpen_yos           = `dc_minpen_yos_`yr_dc_minpen''
			local dc_minpen_yos_max       = `dc_minpen_yos_max_`yr_dc_minpen''
			local dc_minpen_yos_step      = `dc_minpen_yos_step_`yr_dc_minpen''
			local dc_minpen_yos_lvl       = `dc_minpen_yos_lvl_`yr_dc_minpen''
			local dc_minpen_yos_pct       = `dc_minpen_yos_pct_`yr_dc_minpen''
			local dc_minpen_wage_step     = `dc_minpen_wage_step_`yr_dc_minpen''
			local dc_minpen_wage_lvl      = `dc_minpen_wage_lvl_`yr_dc_minpen''
			local dc_minpen_wage_pct      = `dc_minpen_wage_pct_`yr_dc_minpen''
			
			// Maximum pension
			// [TODO: Add same flexibility as in minimum pension]
			local dc_pension_max          = `dc_pension_max_`yr_dc_maxpen''
			local dc_maxpen_age_threshold = `dc_maxpen_age_threshold_`yr_dc_maxpen''
			local dc_maxpen_age_scale     = `dc_maxpen_age_scale_`yr_dc_maxpen''
			local dc_maxpen_yos_threshold = `dc_maxpen_yos_threshold_`yr_dc_maxpen''
			local dc_maxpen_yos_scale     = `dc_maxpen_yos_scale_`yr_dc_maxpen''
			local dc_minpen_wage          = `dc_minpen_adj1' * `dc_minpen_refwage'
			local dc_minpen_wage_max      = `dc_minpen_adj2' * `dc_minpen_refwage'
		} // end if yr <= dc_minpen_max_year
		// else: dc_minpen_base / dc_minpen_refwage / dc_pension_max carry their
		//       cumulatively-indexed values from the prior year's update.


		// Flat proportional contribution rates and reference values 
		// Resolve year's flat parameters (carry forward if beyond data)
		local yr_dc      			= min(`yr', `dc_contributions_max_year')
		local dc_ssc_ee  			= `dc_employee_rate_`yr_dc''
		local dc_ssc_er  			= `dc_employer_rate_`yr_dc''
		local dc_ssc_se  			= `dc_selfemployed_rate_`yr_dc''
		local dc_ssc_gov 			= `dc_government_rate_`yr_dc''
		
		//	Covered wages: override from Excel when within data range;
		//	else keep the running value grown by MPI indexation at end of Stage 8.
		if `yr' <= `dc_contributions_max_year' | `yr' == `startyear' {
			local dc_covered_wage_max 	= `dc_max_covered_`yr_dc''
			local dc_covered_wage_min 	= `dc_min_covered_`yr_dc''	
		} // end if yr <= dc_contributions_max_year


	

		
		************************************************************************
		************************************************************************
		//	Stage 0 - Update DB policy parameters (with carry-forward to last available year)
		// 	Get the year of the most recent policy levels
		local yr_db_policy = min(`yr', `db_policy_max_year')

		//	Core policy parameters
		local db_retage_male          = `db_retage_male_`yr_db_policy''
		local db_retage_female        = `db_retage_female_`yr_db_policy''
		local db_retage_early_male    = `db_retage_early_male_`yr_db_policy''
		local db_retage_early_female  = `db_retage_early_female_`yr_db_policy''
		local db_lumpsum_flag         = `db_lumpsum_flag_`yr_db_policy''
		local db_lumpsum_interest     = `db_lumpsum_interest_rate_`yr_db_policy''
		local db_discount_rate        = `db_discount_rate_`yr_db_policy''
		local db_contribution_rate_ee = `db_contribution_rate_ee_`yr_db_policy''
		local db_contribution_rate_er = `db_contribution_rate_er_`yr_db_policy''
		
		//	Covered wages: override from Excel when within data range;
		//	else keep the running value grown by MPI indexation at end of Stage 8.
		if `yr' <= `db_policy_max_year' | `yr' == `startyear' {
			local db_covered_wage_max 	  = `db_max_covered_`yr_db_policy''
			local db_covered_wage_min 	  = `db_min_covered_`yr_db_policy''
		} // end if yr <= db_policy_max_year

		//	Min/max pension: override from Excel when within data range;
		//	else keep the running value grown by MPI indexation at end of Stage 8.
		if `yr' <= `db_minpen_max_year' | `yr' == `startyear' {
			local yr_db_minpen           = min(`yr', `db_minpen_max_year')
			local yr_db_maxpen           = min(`yr', `db_maxpen_max_year')
			
			// Minimum pension
			local db_minpen_base          = `db_minpen_base_`yr_db_minpen''
			local db_minpen_refwage       = `db_minpen_refwage_`yr_db_minpen''
			local db_minpen_adj1          = `db_minpen_adj1_`yr_db_minpen''
			local db_minpen_adj2          = `db_minpen_adj2_`yr_db_minpen''
			local db_minpen_age           = `db_minpen_age_`yr_db_minpen''
			local db_minpen_age_max       = `db_minpen_age_max_`yr_db_minpen''
			local db_minpen_age_step      = `db_minpen_age_step_`yr_db_minpen''
			local db_minpen_age_lvl       = `db_minpen_age_lvl_`yr_db_minpen''
			local db_minpen_age_pct       = `db_minpen_age_pct_`yr_db_minpen''
			local db_minpen_yos           = `db_minpen_yos_`yr_db_minpen''
			local db_minpen_yos_max       = `db_minpen_yos_max_`yr_db_minpen''
			local db_minpen_yos_step      = `db_minpen_yos_step_`yr_db_minpen''
			local db_minpen_yos_lvl       = `db_minpen_yos_lvl_`yr_db_minpen''
			local db_minpen_yos_pct       = `db_minpen_yos_pct_`yr_db_minpen''
			local db_minpen_wage_step     = `db_minpen_wage_step_`yr_db_minpen''
			local db_minpen_wage_lvl      = `db_minpen_wage_lvl_`yr_db_minpen''
			local db_minpen_wage_pct      = `db_minpen_wage_pct_`yr_db_minpen''
			
			// Maximum pension
			// [TODO: Add same flexibility as in minimum pension]
			local db_pension_max          = `db_pension_max_`yr_db_maxpen''
			local db_maxpen_age_threshold = `db_maxpen_age_threshold_`yr_db_maxpen''
			local db_maxpen_age_scale     = `db_maxpen_age_scale_`yr_db_maxpen''
			local db_maxpen_yos_threshold = `db_maxpen_yos_threshold_`yr_db_maxpen''
			local db_maxpen_yos_scale     = `db_maxpen_yos_scale_`yr_db_maxpen''
			local db_minpen_wage          = `db_minpen_adj1' * `db_minpen_refwage'
			local db_minpen_wage_max      = `db_minpen_adj2' * `db_minpen_refwage'
		} // end if yr <= db_minpen_max_year
		// else: db_minpen_base / db_minpen_refwage / db_pension_max carry their
		//       cumulatively-indexed values from the prior year's update.

		//	Indexation and revalorization coefficients
		local yr_db_index  = min(`yr', `db_index_max_year')
				
		local alpha1                      = `db_alpha1_`yr_db_index''
		local alpha2                      = `db_alpha2_`yr_db_index''
		local alpha3                      = `db_alpha3_`yr_db_index''
		local db_revalor_inflation_coeff   = `db_revalor_inflation_coeff_`yr_db_index''
		local db_revalor_realwage_coeff    = `db_revalor_realwage_coeff_`yr_db_index''
		local db_revalor_anchor_coeff      = `db_revalor_anchor_coeff_`yr_db_index''
		local db_mpi_inflation_coeff 	  = `db_mpi_inflation_coeff_`yr_db_index''
		local db_mpi_realwage_coeff  	  = `db_mpi_realwage_coeff_`yr_db_index''
		local db_mpi_anchor_coeff    	  = `db_mpi_anchor_coeff_`yr_db_index''
		
		di "yr_db_index : `yr_db_index'"
		di "db_revalor_inflation_coeff : `db_revalor_inflation_coeff'"
		di "db_revalor_realwage_coeff : `db_revalor_realwage_coeff'"
		di "db_revalor_anchor_coeff : `db_revalor_anchor_coeff'"
		di "db_mpi_inflation_coeff : `db_mpi_inflation_coeff'"
		di "db_mpi_realwage_coeff : `db_mpi_realwage_coeff'"
		di "db_mpi_anchor_coeff : `db_mpi_anchor_coeff'"
		
		**********
		// 	Assign wage-specific DB pension parameters
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		local yr_pol   = min(`yr', `db_policy_max_year')
		local nb_er   = `db_policy_nbrackets_`yr_pol''
		
		// Loop over the brackets to assign the right values
		forvalues b = `nb_er'(-1)1 {
			replace db_accrual_rate 	= `db_accrual_rate_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' & dens == 1
			replace db_standard_rate 	= `db_standard_rate_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' & dens == 1
			replace db_min_service_req 	= `db_min_service_req_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' & dens == 1
			replace db_accrual_max 		= `db_accrual_max_`b'_`yr_pol''		if reference_wage <= `db_thresh_`b'_`yr_pol'' & dens == 1
			replace db_early_penalty	= `db_early_penalty_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' & dens == 1
			replace db_late_bonus 		= `db_late_bonus_`b'_`yr_pol''		if reference_wage <= `db_thresh_`b'_`yr_pol'' & dens == 1
			} // end forvalues b
			

		

		************************************************************************
		************************************************************************
		//	Stage 1 - Bring in the new affiliates
		//	Note: We start with the baseline observations and append the projected new affiliates
		display " "
		display "Adding new affiliates from `affiliates`yr''"
		append using `affiliates`yr''

		// Give new affiliates a new id number
		local max_id = id[`last_row']
		replace new_affiliate_flag = `yr' if missing(id)
		replace new_affiliate = 0
		replace new_affiliate = 1		if new_affiliate_flag == `yr'	// Flag for when someone becomes a new affiliate
		replace id = `max_id' + (_n - `last_row') if missing(id)			


		***************
		// Clean up the value for new affiliates
		// New affiliates start in first month of the year 
		replace yob = year - age 				if new_affiliate_flag == `yr'
		replace birthmonth = runiformint(1, 12) if new_affiliate_flag == `yr'   	// Randomly assign a birth month
		replace deathmonth = runiformint(1, 12) if new_affiliate_flag == `yr'		// Randomly assign a birth month (destiny)
		replace status = 1  	 				if new_affiliate_flag == `yr'		// Everyone starts out alive
		replace wage_decile_ref = wage_decile  	if new_affiliate_flag == `yr'		// Everyone is given a wage decile ot start
		replace month = 1  		 				if new_affiliate_flag == `yr'		// New affiliates start in first month of the year  
		// Note: As new affiliated are created before we move the data forward, that start with zero values (which are then incremented later on)
		replace los = 0 		 				if new_affiliate_flag == `yr'	 	// Length of service (months)  
		replace loa = 0 						if new_affiliate_flag == `yr'		// Length of affiliation (months) 
		replace spell_length = 0				if new_affiliate_flag == `yr'		// Duration in job or unemployment (months)
		replace dens = 1						if new_affiliate_flag == `yr'		// Flag: Contirbuting this month? 
		replace contribution_density = 1		if new_affiliate_flag == `yr'		// Initial density is 1 until it is updated
		replace log_cod = 0 					if new_affiliate_flag == `yr'		// Initial LN(density) is 0 until it is updated
		replace age_grp = floor(age / 5) * 5	if new_affiliate_flag == `yr'		// Ensure that age group is populated

		
		***************
		// Assign to a pension type
		replace start_year = floor(max(`yr' - (loa / 12), 0))	if new_affiliate_flag == `yr'
		// [TODO: Adjust this so that either the DC or the DB plan can be either first or second]
		replace pension_class = 2 				if new_affiliate_flag == `yr' & start_year >= `dc_year_start'	// Assign pension type to DC if valid year
		replace pension_class = 1 				if new_affiliate_flag == `yr' & start_year < `dc_year_start'	// Assign pension type to DB if valid year
		replace dc_pension_benefit = 0			if new_affiliate_flag == `yr'		// New affiliates start with no DC 
		replace iacc = 0	 					if new_affiliate_flag == `yr'		// Initial invidual account balance


		
		***************
		// Assign density_decile by sampling from P(density_decile_ref | wage_decile_ref)
		// Loop over wage deciles
		forvalues w = 1/10 {
			// Loop over decile densities
			forvalues d = 1/10 {
				replace density_decile = `d' if missing(density_decile) & new_affiliate_flag == `yr' & wage_decile_ref == `w' & runiform() <= `cdf_`w'_`d''
			} // end forvalues d
		} //  end forvalues w



		
		************************************************************************
		************************************************************************
		//	Stage 2 - Project existing dataset forward
		// 	Project the last observation for each individual forward
		// 	Note: At this point we have new affiliates for the new year, but not yet the existing population

		//	Pull forward the last month of observations into the new year
		capture drop expanded
		expand 2 if year == `lastyear' & month == 12 , generate(expanded)	
		replace month = 1    if expanded
		replace year  = `yr' if expanded
		
		//	Project for the rest of the months in the year
		capture drop to_expand
		generate to_expand = 0
		replace  to_expand = 13 - month if year == `yr'
		expand to_expand
		drop to_expand
		
		//	Rename the months in the expanded dataset to cover the year
		bysort id year: replace month = (month - 1) + _n if year == `yr'
		
		//	Copy the last month of the last year (and save it as month 0, so we can use it in our time series data)
		capture drop last_obs_copy
		expand 2 if (year == `lastyear' & month == 12) | (new_affiliate_flag == `yr' & month == 12) , generate(last_obs_copy)	
		replace month = 0    if last_obs_copy 
		replace year  = `yr' if last_obs_copy
		
	
		// Update the labour market assumptions
		local turnover_target = `turnover_`yr''
		local emp_rate_growth = `emp_rate_`yr''



		************************************************************************
		************************************************************************
		//	Stage 3 - Compute the variables that we need and then drop the previous year
		//	Note: We do this for computational reasons (otherwise this takes way too long to run)

		// Grab the prvious year's wages
		// Note: We only calculate it like this for the start year. Otherwise we push forward the current average [see below]
		if `yr' == `startyear' {
			quietly summarize wage if year == `yr' - 1 & month > 0 
			local old_wage = r(mean)
			} // if year == `startyear'
		
		// Keep only the current year
		keep if year == `yr'
		
		
		// Update person's age
		// [TODO: For computational reasons, everybody ages in January, do we want to change this?]
		// [TODO: Check that we need the if statment status != 99 depending on how we deal with dead people]
		*replace age = age + 1 if status != 99	// Update age if person is not dead
		// Note: Moved to the month loop
		

		************************************************************************
		************************************************************************
		// Compute some pension-rule-specific indicators (for determining which transition matrix to use)	
		// Months until reaching eligible retirement age
		replace  age_gap = max(`db_retage_male'   - age, 0) * 12 if gender == 1 & pension_class == 1 // Male - DB pension
		replace  age_gap = max(`db_retage_female' - age, 0) * 12 if gender == 2 & pension_class == 1 // Female - DB pension
		replace  age_gap = max(`dc_retage_male'   - age, 0) * 12 if gender == 1 & pension_class == 2 // Male - DC pension
		replace  age_gap = max(`dc_retage_female' - age, 0) * 12 if gender == 2 & pension_class == 2 // Female - DC pension
		
		// Months of contributions requred to be eligible for an old-age pension
		replace los_gap = max(12 * db_min_service_req - los, 0) if pension_class == 1 // Defined-benefit pension
		replace los_gap = max(12 * `dc_min_service_req' - los, 0) if pension_class == 2	// Define-contribution pension

		replace pension_gap = max(age_gap, los_gap)
		
		// Indicator: person has no hope of being eligible for a pension
		replace no_hope = (los_gap  >= age_gap)
		
		// Determine the earliest age at which people can take retirement
		// Note: This is using DB policy parameters, edit so that we use DC parameters for
		replace retirement_age = (age >= `db_retage_early_male')   if gender == 1 & pension_class == 1 // Male - DB pension
		replace retirement_age = (age >= `db_retage_early_female') if gender == 2 & pension_class == 1 // Female - DB pension
		replace retirement_age = (age >= `dc_retage_early_male')   if gender == 1 & pension_class == 2 // Male - DC pension
		replace retirement_age = (age >= `dc_retage_early_female') if gender == 2 & pension_class == 2 // Female - DC pension

		
		// Implied age that person would be eligible for retirement
		replace implied_retage = age + (los_gap / 12)
		
		// Update the merging group
		// Group 1 : Worker will accumulate enough service time before retirement
		// Group 2 : Worker will not accumulate enough service time before normal retirement, but can work longer and be eligible
		// Group 3 : Worker will not accumulate enough service time before normal retirement, and cannot reasonably work longer and be eligible
		replace group = 1 if age_gap >= los_gap												
		replace group = 2 if age_gap <  los_gap & implied_retage <= `max_eligibility_age'	
		replace group = 3 if age_gap <  los_gap & implied_retage >  `max_eligibility_age'	
		
		// Update the merge in variables (depending on which group a person is in)
		replace age_merge = .
		replace age_merge = age   if group == 1
		replace service_gap = .
		replace service_gap = ceil(los_gap / 12) if group == 2
		
		
		**********
		// Update in life expectancy data
		capture drop life_expectancy
		// Cap merge year so projection years beyond data use the last available life expectancy
		capture drop year_merge
		generate year_merge = min(year, `lifeexpect_max_year')
		join life_expectancy, from(`life_expect_database') by(year_merge age gender) keep(1 3) nogenerate	// ftools version of merge [faster]
		drop year_merge
		
		
		************************************************************************
		************************************************************************
		//	Stage 4 - Determine mortality
		
		// 	Merge in mortality data
		noisily display " "
		noisily display "Merging in mortality rates..."
		capture drop mortality
		// Cap merge year so projection years beyond data use the last available rates
		capture drop year_merge
		generate year_merge = min(year, `mortality_max_year')
		join mortality, from(`mortality_database') by(gender age year_merge) keep(1 3) nogenerate	// ftools version of merge [faster]
		drop year_merge

		// Dead people don't have a mortality rate
		replace mortality = . if status == 99
		
		// Sample probability of dying
		tempvar randnum_mortality
		generate `randnum_mortality' = runiform()

		
		
		************************************************************************
		************************************************************************
		//	Stage 5 - Merge in transitions and wage dynamics
		// 	Note: At this point, we have a new year of observations, but with the same wage as the previous year
		
	
		*******************
		// Update the mean and sd of wages by decile, age and gender in the current year.
		// Then sample to give the wages to new entrants and new affiliates.
		// Get the mean of the updated mean, sd, min, and max
		replace age_grp_capped = min(age_grp, `wage_stats_max_age_grp')
		preserve
			gcollapse (mean) wage_mean_decile wage_sd_decile wage_min_decile wage_max_decile, by(wage_decile_ref gender age_grp_capped)
				 
			tempfile wage_stats_yr
			save `wage_stats_yr', replace
		restore
		
		
		// Drop old values and join the new ones back onto the full dataset
		capture drop wage_mean_decile wage_sd_decile wage_min_decile wage_max_decile
		join wage_mean_decile wage_sd_decile wage_min_decile wage_max_decile, 	///
				from(`wage_stats_yr') by(wage_decile_ref gender age_grp_capped) ///
				keep(1 3) nogenerate

		
		*******************
		//	Compute probability of transitioning out of work
		// Note: Function of age, gender, job tenure, los_gap and wage decile
		estimates restore job_exit_stored	
		predict job_exit_predict, xb
		replace transition_out = 1 - exp(-exp(job_exit_predict))
		drop job_exit_predict
		
		//	Compute probability of transitioning into of work
		// Note: Function of age, gender, unemploment duration, log_cod, los_gap and wage decile
		estimates restore job_entry_stored	
		predict job_entry_predict, xb
		replace transition_in = 1 - exp(-exp(job_entry_predict)) 
		drop job_entry_predict 
		
		
		**********
		// Adjust transition rates to ensure that the employment rate follows the growth trajectory
		noisily display " "
		noisily display "Adjusting transition rates to match labour market path..."
		
		**********
		// Update population to account for new affiliates
		tempvar affiliates
		gegen `affiliates' 	  	= count(status!=99)  		 if month > 0   //, by(wage_decile_ref)	// Sample population count
		replace affiliates 	 	= `affiliates' / 12						// Total number of affiliates
		
		**********
		// Compute inflow and outflow targets:
		quietly summarize new_affiliate if month == 1
		local delta_affiliates = r(sum)							// Number of new affiliates (who count towards inflows)	
		
		// Get the current employment rate
		quietly summarize dens if month == 1
		local current_emp_rate = r(mean)
		
		// Compute target flows in and out of employment
		local target_emp_rate 	  	= `target_emp_rate_last' + (`emp_rate_growth' / 100)	// The global target employment rate 
		local target_emp_rate_last 	= `target_emp_rate' 									// Store the previous target employment rate 
		local delta_employment      = (`target_emp_rate' - `current_emp_rate') * affiliates	// Number of jobs added 
		local gross_flows      		= (`turnover_target' / 100) * affiliates * 12   		// Number of people changing states (annual)
		local balancing_exits 		= min((`gross_flows' + `delta_employment') / 2, 0)		// Balancing exits   (when entries are constrained)
		local balancing_entry 		= min((`gross_flows' - `delta_employment') / 2, 0)		// Balancing entries (when exits are constrained)

		
		**********
		// Adjust outflow rates:
		
		// Update exits_target to hit employment and turnover targets 
		replace exits_target = max((`gross_flows' - `delta_employment') / 2	 - `balancing_exits', 0)

		// Get the unadjusted expected number of exits (sum of transition_out for those working)
		tempvar expected_exits 
		gegen `expected_exits' = sum(transition_out if dens == 1 & month > 0) 
		replace expected_exits = `expected_exits'
		
		// Update transition_out rate adjustment based on exits target
		replace outflow_adjustment = exits_target / `expected_exits'
		replace transition_out = transition_out * outflow_adjustment
	
		
		**********
		// Adjust inflow rates:
		
		// Update reentrants_target to hit employment and turnover targets  
		replace reentrants_target = max((`gross_flows' + `delta_employment') / 2 - `balancing_entry', 0)	

		// Get the unadjusted expected number of re-entrants (sum of transition_in for those not working)
		tempvar expected_reentrants 
		gegen `expected_reentrants' = sum(transition_in if dens == 0 & month > 0 ) 
		replace expected_reentrants = `expected_reentrants'

		// Update transition_out rate adjustment based on exits target
		replace inflow_adjustment = reentrants_target / `expected_reentrants'
		replace transition_in = transition_in * inflow_adjustment
		
		
		**********
		// Apply the transition probabilities
		noisily display " "
		noisily display "Determining transitions in and out of work and implementing wage growth..."
		noisily display " "
		noisily display "Implementing wage growth dynamics..."
		noisily display " "
		noisily display "Assigning wages to labour market entrants..."
		
		// Replace the month and year of the last month of the last year now that we have trimmed the data down
		// Note: we do this for the tsset, and then revert
		replace year  = `lastyear' 	if month == 0 
		replace month = 12    		if month == 0 
		
		// Set up the data as time series data
		// Note: We have to do this each year because we are adding new afifliates 
		// 		 each year that need to be included in the time series panel
		capture drop date
		generate date = ym(year, month)
		tsset id date
		*sort id date 
		
		
		// Switch month and year back
		// Note: we do this for the tsset, and then revert
		replace month = 0    	if year  == `lastyear'
		replace year  = `yr' 	if month == 0 
		
		

	
		************************************************************************
		************************************************************************
		************************************************************************
		// Loop across the months to update transitions and wages
		forvalues month = 1/12 {	
			// Update age (based on month)
			replace age = age + 1 if birthmonth == `month' & status != 99
			replace age_grp = floor(age / 5) * 5  // 5-year grouping
			
			// Update mortality (based on month)
			replace status = 99 if mortality > `randnum_mortality' & deathmonth == `month'
			
			//	Update transition probabilities using a model approach 
			//	Include job tenure and unemployment spells when determining transition rates
			
			// Use the spell length from last month to determine transition probabilities for this month
			replace spell_length = l.spell_length if month == `month'
			
			
			*******************
			// Note: This is the original code where we predict transition probability each 
			
			// Compute probability of transitioning out of work
			// Note: Function of age, gender, job tenure, and wage decile
			estimates restore job_exit_stored	
			predict job_exit_predict if month == `month', xb
			replace transition_out = 1 - exp(-exp(job_exit_predict))     if month == `month'
			replace transition_out = max(min(transition_out * outflow_adjustment, 1), 0) if month == `month' // Anchor outflows to annual targets
			drop job_exit_predict
			
			// Compute probability of transitioning into of work
			// Note: Function of age, gender, unemploment duration, and wage decile
			estimates restore job_entry_stored	
			predict job_entry_predict if month == `month', xb
			replace transition_in = 1 - exp(-exp(job_entry_predict))    if month == `month' 
			replace transition_in = max(min(transition_in * inflow_adjustment, 1), 0)   if month == `month' // Anchor inflows to annual targets
			drop job_entry_predict 

		
			*******************		
			// Ensure new affiliate consistency
			// Right now: Everybody becomes a new affiliate in Janaury
			*replace new_affiliate = 0		if month != 1
			
			// Record the data from the previous period
			replace wage_decile	= l.wage_decile		if month == `month' 
			replace wage 		= l.wage			if month == `month'

			
			*******************		
			// Compute transitions
			// Sample transitions in and out of active contributions (choose a random number)
			
			// Transitioning out of active contributions (i.e. formal work)
			replace exiter = (runiform() < transition_out & wage_decile > 0) if month == `month'
			
			// Transitioning into active contributions (i.e. formal work)
			replace reentrant = (runiform() < transition_in & wage_decile == 0) if month == `month'

			
			
			
			// Update reference wages and wage deciles for exiters and enterers
			// Exiters:
			replace wage_ref    = wage 	if month == `month' & exiter == 1
			replace wage    	= .  	if month == `month' & exiter == 1
			replace dens    	= 0 	if month == `month' & exiter == 1
			replace wage_decile = 0     if month == `month' & exiter == 1
			// Reentrants:
			replace wage_decile = wage_decile_ref if month == `month' & reentrant == 1
			// Both:
			replace spell_length = 1 if month == `month' & (reentrant == 1 | exiter == 1)

		
			// Update the density and length of service variables (los)
			replace dens = (wage_decile >  0) 	if month == `month'			// If working: Note the density flag
			replace los = l.los + 1 if month == `month' & wage_decile >  0	// If working: Increment length of service 
			replace los = l.los     if month == `month' & wage_decile == 0	// If not working: Do not increment length of service
			replace loa = l.loa + 1 if month == `month' 					// Increment length of affiliation 

			replace contribution_density = los / loa if month == `month' 	// Update contribution density 
			replace log_cod = log(max(contribution_density, 0.001))
			
			// Update los-gap and pension-gap calculations
			replace los_gap = max(12 * `db_min_service_req' - los, 0) if pension_class == 1 // DB pension plan
			replace los_gap = max(12 * `dc_min_service_req' - los, 0) if pension_class == 2 // DC pension plan
			replace pension_gap = max(age_gap, los_gap)
			
			// Increment duration of spell (job or unemployment)
			replace spell_length = l.spell_length + 1  if month == `month' & !(reentrant == 1 | exiter == 1)

			

			*******************		
			// Assign wages to reentrants
			// Special case: those that move from out-of-work to work need to have a given wage

pause "stop0"			
			// Sample a wages to new entrants and new affiliates
			// Note: bounded by the min and max of the decile
			// New affiliates are given the same wage for the entire first year
			replace wage = max(min(rnormal(wage_mean_decile, wage_sd_decile), wage_max_decile), wage_min_decile) if missing(wage) & new_affiliate == 1 & dens == 1

			
			// We give reentrants the same wage they left with (adjusted for wage growth)
			// Note: We give reentrants the same wage they left with so that we can assign wage penalties (in a later revision)
			// Note: If we don't have a previous wage then we sample a wage
			replace wage = wage_ref if month == `month' & reentrant == 1 & !missing(wage_ref)
			replace wage = max(min(rnormal(wage_mean_decile, wage_sd_decile), wage_max_decile), wage_min_decile) if month == `month' & reentrant == 1 & missing(wage_ref)

pause "stop00"			
			

			*******************
			// Update individual accounts
			// [TODO: Add in this updating]
			

	
			} // end forvalues month
		************************************************************************
		************************************************************************
		************************************************************************

		*******************
		// Update the reference wage for re-entrants who didn't have a wage in the past
		tempvar wage_ref_update
		gegen `wage_ref_update' = max(wage_ref), by(id)
		replace wage_ref = `wage_ref_update' if missing(wage_ref)
			
			

		*******************		
		// Compute wage dynamics
		// Note: This is done annually and not monthly
			
		//	Merge in the wage growth database
		noisily display " "
		noisily display "Merging in the wage growth database..."
		capture drop wage_growth
		// Cap merge year so projection years beyond data use the last available growth rate
		capture drop year_merge
		generate year_merge = min(year, `wage_growth_max_year')
		join wage_growth, from(`wage_growth_database') by(year_merge) keep(1 3) nogenerate	// ftools version of merge [faster]
		drop year_merge
		
		// Get the user determined wage growth 
		// Note: this works as we only simulate one year at a time
		quietly summarize wage_growth 
		local wage_growth_user = r(mean) / 100
		replace debug_wage_growth_user = `wage_growth_user'
			
		//	Load in model parameters to compute relative wages
		//	Note: the model uses the following inputs:
		//			- wage_decile_age_sex (wage deciles by age and sex)
		//			- gender (1 = male, 2 = female)
		//			- age (in years)
		estimates restore lifecycle_stored
		
		// Compute maximum reliable age (so that older ages, where there are only a few observations do not skew results)
		replace age_m = min(age, `max_reliable_age')

		
		// Predict relative wage 
		capture drop relative_wage_growth
		predict relative_wage_growth if dens == 1, xb
		
		// Beyond the age range the model was estimated on, we have no evidence
		// for an age-specific growth differential. Topcoding age_m prevents the
		// cubic from being evaluated out of range, but it would otherwise still
		// apply whatever differential was fitted at the boundary indefinitely to
		// anyone who remains employed past that age. Revert to the neutral/
		// aggregate rate (100) once true age exceeds the reliable range.
		replace relative_wage_growth = 100 if age > `max_reliable_age' & !missing(relative_wage_growth)


		// Adjust global wage growth to reflect age-sex-decile profiles
		replace sim_wage_growth = wage_growth * relative_wage_growth / 100
	
		// Adjust wages
		replace wage     = wage     * (1 + (sim_wage_growth / 100))  if dens == 1

		**********
		// Re-adjust wages to ensure that user-defined wage growth is obtained
		// Get the average wage of the sample (this year)
		quietly summarize wage if month > 0 
		local new_wage = r(mean)
		replace average_wage = `new_wage'
		
		// Compare to average wage of last year (defined earlier in the code)
		local wage_growth_obs = (`new_wage' / `old_wage') - 1
		
		// Compute aggregate adjustments
		local wage_adjustment = (1 + `wage_growth_user') / (1 + `wage_growth_obs')

		// Adjust wages to reflect user-defined aggregate wage growth
		// Note: For those not working, reference wages are grown by the economy-wide average
		replace wage     = wage     * `wage_adjustment'	if month > 0 
		replace wage_ref = wage_ref * (1 + `wage_growth_user') if month > 0 
		
		// Save the new wage as the old wage [we will use it for next year's wage adjustments]
		local old_wage = `new_wage'
		
	
		


	

		
		************************************************************************
		************************************************************************
		//	Stage 6 - Determine mortality
		
// 		// 	Merge in mortality data  
// 		noisily display " "
// 		noisily display "Merging in mortality rates..."
// 		capture drop mortality
// 		join mortality, from(`mortality_database') by(gender age year) keep(1 3) nogenerate	// ftools version of merge [faster]
//		
// 		// Dead people don't have a mortality rate
// 		replace mortality = . if status == 99
//		
// 		// Sample probability of dying
// 		tempvar randnum_mortality
// 		generate `randnum_mortality' = runiform()
//		
// 		// Assign mortality randomly
// 		replace status = 99 if mortality > runiform() // Status 99 means dead
		
		// Housekeeping for when people die
		replace deathyear = `yr'	 	if status == 99 & !missing(mortality)	// Record year died
		replace wage_at_death = wage 	if status == 99 & !missing(mortality)
		replace wage = . 			 	if status == 99
		replace db_pension_benefit = 0  if status == 99                         // Stop paying pension
		replace dc_pension_benefit = 0  if status == 99                         // Stop paying pension
		replace dens               = 0  if status == 99                         // Not contributing
		

		
		



		************************************************************************
		************************************************************************
		//	Stage 7 - Apply disability and survivor
		// 	[TODO: Sort out disability and survivor data - Talk to Marola and Asta about this]
		
		// Once rate files are available, implement as follows:
		// Disability:
		//   import delimited "`indir'\disability_rates_`country'.csv", clear   // columns: age gender year disability_rate
		//   tempfile disability_database; save `disability_database', replace   // (load before main loop)
		//   Inside loop: join disability_rate, from(`disability_database') by(age gender year) keep(1 3) nogenerate
		//   replace status = 3 if status == 1 & disability_rate > runiform()   // Status 3 = disabled
		// Survivor (widowhood):
		//   Requires a separate survivor_rate file and a record of deceased affiliates (see the TODO at Stage 11
		//   about keeping dead people in the dataset). Basic approach:
		//   generate widow_flag = 0
		//   replace  widow_flag = 1  if status[_n-1] == 99 & widow_rate > runiform()
		//   replace  status     = 4  if widow_flag   // Status 4 = widowed

		
		
		

		************************************************************************
		************************************************************************
		//	Stage 8 - Index values and Compute annual reference values
		//	Note: we do this so that we can carry forward some summary statistics
		//  Note: At this point, all mortality, disabiity, and job transitions have been calculated
			
		// Update contribution density
		replace contribution_density = los / loa 
		replace log_cod = log(max(contribution_density, 0.001))
		
		// Update years of service
		replace yos = los / 12	
		
		
		**********
		//	Index mean, sd, min, and max wages by decile, gender, and age
		replace wage_mean_decile = wage_mean_decile * (1 + `wage_growth_user')
		replace wage_sd_decile   = wage_sd_decile   * (1 + `wage_growth_user')
		replace wage_min_decile  = wage_min_decile  * (1 + `wage_growth_user')
		replace wage_max_decile  = wage_max_decil   * (1 + `wage_growth_user')

	
		**********
		//	Index previous reference values
		
		// Load in the annual assumed inflation
		// Cap merge year so projection years beyond data use the last available indexation values
		capture drop pindex_inflation pindex_realwage pindex_anchor
		capture drop year_merge
		generate year_merge = min(year, `indexation_max_year')
		join pindex_inflation pindex_realwage pindex_anchor, from(`indexation_database') by(year_merge) keep(1 3) nogenerate
		drop year_merge
		quietly summarize pindex_inflation
		local pindex_inflation = r(mean)
		quietly summarize pindex_realwage
		local pindex_realwage  = r(mean)
		quietly summarize pindex_anchor
		local pindex_anchor    = r(mean)


		// Compute revalorization rate
		local db_revalorization_rate = ( `db_revalor_inflation_coeff' * `pindex_inflation' ///
									   + `db_revalor_realwage_coeff'  * `pindex_realwage'  ///
							           + `db_revalor_anchor_coeff'    * `pindex_anchor') / 100
		replace debug_db_revalorization_rate = `db_revalorization_rate'
		
		// Update reference wages if type 1 (best of last x years)
		if `ref_wage_type' == 1 {
			replace reference_wage = reference_wage * (1 + `db_revalorization_rate') if pension_class == 1	// DB pensioners
			replace reference_wage = reference_wage * (1 + `wage_growth_user')       if pension_class == 2	// DC pensioners
			} // end if statement
								
		// Update reference wages if type 2 or 3 (best x oy y years)
		if `ref_wage_type' == 2 | `ref_wage_type' == 3 {
			forvalues i = 1/`ref_wage_n' {
				replace bestwage`i' = bestwage`i' * (1 + `db_revalorization_rate') if pension_class == 1	// DB pensioners - indexed by policy parameters
				replace bestwage`i' = bestwage`i' * (1 + `wage_growth_user')       if pension_class == 2	// DC pensioners - indexed by user defined wage growth
				} // end forvalues
			} // end if statement
		
		
		**********
		// Reference wage placeholders
		
		// Compute average wage for the year
		capture drop  avg_wage_ind
		gegen  avg_wage_ind = mean(wage)  , by(id)	
	
		// Determine covered wages
		replace db_covered_wage = max(min(wage, `db_covered_wage_max'), `db_covered_wage_min') if dens == 1
		replace dc_covered_wage = max(min(wage, `dc_covered_wage_max'), `dc_covered_wage_min') if dens == 1
		
		// Compute average covered wage across the year
		capture drop avg_db_covered_wage
		gegen avg_db_covered_wage = mean(db_covered_wage)  , by(id)

		// Compute average covered wage across the year
		capture drop avg_dc_covered_wage
		gegen avg_dc_covered_wage = mean(dc_covered_wage)  , by(id)
		// dc_covered_wage is only set for dens==1 months; inactive months carry the prior
		// year's December value (from Stage 2 expand), making avg_dc_covered_wage non-missing
		// for workers who were previously active but are inactive this year.  That stale value
		// would incorrectly drive the reference-wage EWMA (Step 2 below).  Null it out for
		// workers with zero active months this year so Step 2 is skipped for them.
		tempvar _active_this_yr
		gegen `_active_this_yr' = max(dens * (month > 0)), by(id)
		replace avg_dc_covered_wage = . if `_active_this_yr' == 0
		replace avg_db_covered_wage = . if `_active_this_yr' == 0
		drop `_active_this_yr'
		
		

		// 	Here we update placeholder values that record the current best years of contributions
		//	Get the N highest wages
		if `ref_wage_type' == 2 {
			// The Lowest wage of best N wages
			tempvar refwage_min 
			gegen `refwage_min' = rowmin(bestwage*) 
			// Compare the lowest best wage to the current wage (replace if current wage is bigger)
			forvalues i = 1/`ref_wage_n' {
				replace bestwage`i' =  avg_db_covered_wage 	if  avg_db_covered_wage > bestwage`i' & bestwage`i' == `refwage_min' & pension_class == 1 // DB pensioners
				replace bestwage`i' =  avg_dc_covered_wage 	if  avg_dc_covered_wage > bestwage`i' & bestwage`i' == `refwage_min' & pension_class == 2 // DC pensioners
				} // end forvalues i
			} //end if `ref_wage_type' == 2
			
		//	Get the N highest wages of the M last years
		if `ref_wage_type' == 3 {
			// Step 1: expire slots older than M years — clear BOTH wage and year
			forvalues i = 1/`ref_wage_n' {
				replace bestwage`i' = . if bestyear`i' < (`yr' - `ref_wage_m')
				replace bestyear`i' = . if bestyear`i' < (`yr' - `ref_wage_m')
				} // end forvalues i
			// Step 2: recompute minimum AFTER expiry (expired slots are now missing, rowmin ignores them)
			tempvar refwage_min 
			gegen `refwage_min' = rowmin(bestwage*) 
			// Step 3: replace the weakest remaining slot if current wage beats it
			forvalues i = 1/`ref_wage_n' {
				replace bestwage`i' =  avg_db_covered_wage if  avg_db_covered_wage > `refwage_min' & bestwage`i' == `refwage_min' & pension_class == 1 // DB pensioners
				replace bestyear`i' = `yr'                 if  avg_db_covered_wage > `refwage_min' & bestwage`i' == `refwage_min' & pension_class == 1 // DB pensioners
				
				replace bestwage`i' =  avg_dc_covered_wage if  avg_dc_covered_wage > `refwage_min' & bestwage`i' == `refwage_min' & pension_class == 2 // DC pensioners
				replace bestyear`i' = `yr'                 if  avg_dc_covered_wage > `refwage_min' & bestwage`i' == `refwage_min' & pension_class == 2 // DC pensioners
				} // end forvalues i
			}  // end if `ref_wage_type' == 3
		**********	
		
		
		**********
		// Update variables for determining labour market conditions
		
		// Store the population and employment totals as well as the total flows
		tempvar samp
		tempvar emp
		tempvar reentrants
		tempvar affiliates
		tempvar new_affiliates
		tempvar exiters

		
		// Note: We use this method so that we can disaggregate results by gender-age-decile (if we want to)
		gegen `samp' 	  		= count(dens)  		 if month > 0  //, by(wage_decile_ref)	// Population count
		gegen `emp'  	  		= sum(dens)    		 if month > 0  //, by(wage_decile_ref) 	// Employment count
		gegen `reentrants'  	= sum(reentrant)     if month > 0  //, by(wage_decile_ref)	// Number of re-entrants
		gegen `affiliates'      = sum(status!=99)    if month > 0  //, by(wage_decile_ref)	// Number of total affiliates
		gegen `new_affiliates'  = sum(new_affiliate) if month > 0  //, by(wage_decile_ref)	// Number of new affiliates
		gegen `exiters'  		= sum(exiter)  		 if month > 0  //, by(wage_decile_ref)	// Number of exiters

		
		// This is mostly for reporting (and for adjusting transition rates)
		replace sample_pop 	 	= `samp' / 12						// Annual Population count
		replace affiliates 	 	= `affiliates' / 12					// Number of total affiliates
		replace employment      = `emp'	/ 12						// Number of affiliates who are contributing ("working")
		replace employment_rate = 100 * employment / affiliates 	// "Employment rate": Share of affiliates who are working
		replace unemployment    = affiliates - employment			// Number of affiliates who are not contributing ("not working")
		replace reentrants      = `reentrants'						// Number of re-entrants
		replace new_affiliates  = `new_affiliates'					// Number of new affiliates
		replace exiters 		= `exiters'							// Number of exiters

		// Compute inflow and outflow rates
		// Note: We do not include new_affiliates in the inflow rate as they do not come from the stock of non-contributing affilates
		replace inflow_rate   = 100 * reentrants / unemployment 					// Share of "unemployed" flowing into "employment"
		replace outflow_rate  = 100 * exiters / employment							// Share of "employed" flowing into "unemployment"
		replace turnover_rate = 100 * (exiters + reentrants) / (affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			
	

		************************************************************************
		************************************************************************
		//	Stage 9 -  Update DC individual account balance (iacc)
		//	Done annually (once per year, after all monthly transitions are resolved).

		// Count months actively contributing this year (dens==1, exclude month-0 lag copy)
		capture drop months_contributed_yr
		gegen months_contributed_yr = sum(dens * (month > 0)), by(id year)

	
		// Covered wage: cap at the insurable ceiling
		replace dc_covered_wage = max(min(wage, `dc_covered_wage_max'), `dc_covered_wage_min') if dens == 1

		**********
		// 	Employer pension contribution rates by income bracket and year
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		local yr_er   = min(`yr', `dc_employer_max_year')
		local nb_er   = `dc_employer_nbrackets_`yr_er''
		replace employer_ssc_rate = 0
		forvalues b = `nb_er'(-1)1 {
			replace employer_ssc_rate = `dc_employer_rate_`b'_`yr_er'' / 100 if wage <= `dc_employer_thresh_`b'_`yr_er'' & dens == 1
			} // end forvalues b
		replace employer_ssc_rate = employer_ssc_rate + (`dc_ssc_er' / 100)  if dens == 1 // Add in the flat rate employer ssc

		// Compute employer contributions
		replace dc_employer_ssc = 0
		*replace dc_employer_ssc = dc_covered_wage * employer_ssc_rate * months_contributed_yr
		replace dc_employer_ssc = dc_covered_wage * employer_ssc_rate if dens == 1


		
		**********
		//  Government social security subsidies (if any) 
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		// [TODO: This works for the flat rate of mexico, need to generalize to proportional subsidies in other countries]
		local yr_gov    = min(`yr', `dc_gov_max_year')	// Latest year of policy parameters
		local nb_gov    = `dc_gov_nbrackets_`yr_gov''	// Number of brackets
		replace gov_subsidy = 0
		// Loop backwards through the brackets to get the contribution amount
		forvalues b = `nb_gov'(-1)1 {
			replace gov_subsidy = months_contributed_yr * `dc_gov_subsidy_`b'_`yr_gov'' if wage <= `dc_gov_thresh_`b'_`yr_gov'' & dens == 1
			} // end forvalues b
		
		// Compute government contributions
		replace government_ssc_rate = 0
		replace government_ssc_rate = `dc_ssc_gov' / 100 if dens == 1
		replace dc_government_ssc = 0
		*replace dc_government_ssc = (gov_subsidy +  dc_covered_wage * government_ssc_rate) * months_contributed_yr
		replace dc_government_ssc = gov_subsidy + (dc_covered_wage * government_ssc_rate) if dens == 1

			
			

		*********	
		//  Employee pension contribution rates by income bracket and year 
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		local yr_ee   = min(`yr', `dc_employee_max_year')
		local nb_ee   = `dc_employee_nbrackets_`yr_ee''
		replace employee_ssc_rate = 0
		forvalues b = `nb_ee'(-1)1 {
			replace employee_ssc_rate = `dc_employee_rate_`b'_`yr_ee'' / 100 if wage <= `dc_employee_thresh_`b'_`yr_ee'' & dens == 1
			} // end forvalues b
		replace employee_ssc_rate = employee_ssc_rate + (`dc_ssc_ee' / 100) if dens == 1 // Add in the flat rate employer ssc

		// Compute employer contributions
		replace dc_employee_ssc = 0
		*replace dc_employee_ssc = dc_covered_wage * employee_ssc_rate * months_contributed_yr		
		replace dc_employee_ssc = dc_covered_wage * employee_ssc_rate if dens == 1	

		
		
		*********
		//  Self-employed pension contribution rates by income bracket and year
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		// [TODO: Add in this section, but we don't have the means to idenify self-employed right now]
		
		
		*********
		//  Fund fees and performance assumptions [varies by year]
		local yr_perf   			= min(`yr', `dc_performance_max_year')
		local dc_return_gross  		= `dc_return_gross_`yr_perf''		// In-year gross return
		local dc_fees_mer  			= `dc_fees_mer_`yr_perf''			// In year Management expenese ratio
		local dc_fees_flat  		= `dc_fees_flat_`yr_perf''			// In-year flat fees (if any)
		local dc_annuity_rate 		= `dc_annuity_rate_`yr_perf''		// Real discount rate used in annuity factor formula
		local dc_annuity_indexed 	= `dc_annuity_indexed_`yr_perf''	// 1 = index DC pension post-retirement; 0 = fixed nominal
		local dc_net_return 		= `dc_return_gross' - `dc_fees_mer'	// Annual net return
		*local dc_net_return_month 	= (1 + `dc_net_return')^(1/12)	// Monthly return on account
		

		
		*********
		// Total annual DC contribution (employer, employee, and government subisdies [and possibly self-employed])
		replace dc_total_contrib = dc_employer_ssc + dc_employee_ssc + dc_government_ssc
		capture drop dc_contributions
		bysort id (year): generate dc_contributions = sum(dc_total_contrib * (month > 0))	// Exclude month 0 to avoid double counting

		// Credit contributions and apply net investment return to iacc
		// Note: We accumulate contributions but only apply the annual growth at the end of the year.
		//		 This is an approximation that saves some compute time (by keeping the calculations out of the monthly loop).
		//   iacc(t) = [iacc(t-1) + dc_contrib(t)] x (1+r)
		*replace iacc = (iacc + dc_total_contrib)  * (1 + `dc_net_return') if status != 99 // If not dead
		replace iacc = (iacc + dc_contributions)  * (1 + `dc_net_return') if status != 99 // If not dead
		
		
		***************
		// Compute the Value of the Annuity
		// [TODO: Confirm if we need to adjust this based on if the pension is indexed or not, I think we do]
		
		// Present-value annuity factor
		replace dc_annuity_factor = (1 - (1 + `dc_annuity_rate')^(-life_expectancy))  / `dc_annuity_rate'
	
		// Present-value annuity factor for the next year (approximate: subtract 1)
		replace dc_annuity_factor_next = (1 - (1 + `dc_annuity_rate')^(-(life_expectancy - 1))) / `dc_annuity_rate'
		
		// Compute expected pension benefit
		replace dc_annuity = iacc / (12 * dc_annuity_factor)

		
		**********
		// Determine DC pension eligibility:
		// Eligible for pension based on length of service
		replace dc_pension_elig_mincont = ((los / 12) >= `dc_min_service_req')
		
		// Eligible for pension on the basis of minimum pension amount
		// [TODO: This is a Mexico specific rule, add a toggle for these types of rules]
		replace dc_pension_elig_minpen = (dc_annuity >= dc_pension_minpen)
		
		// Eligible for pension on the basis of age
		replace dc_pension_elig_early = (age >= `dc_retage_early_male')   * dc_pension_elig_minpen  if gender == 1
		replace dc_pension_elig_early = (age >= `dc_retage_early_female') * dc_pension_elig_minpen  if gender == 2		
		
		// Eligible for pension on the basis of age
		replace dc_pension_elig_age = (age >= `dc_retage_male')   if gender == 1
		replace dc_pension_elig_age = (age >= `dc_retage_female') if gender == 2		
		
		
		// Eligile for a pension if you meet all of the eligibility criteria
		replace dc_pension_elig = (dc_pension_elig_mincont & (dc_pension_elig_age | dc_pension_elig_early))	if pension_class == 2
		
				
		***************
		//	Compute the minimum guarenteed pensions (minimum monthly amounts):
		//	Note: Minimum pension can differ by age, wage, and years of service (or it can be flat)
		replace dc_pension_minpen = `dc_minpen_base'
		
		// Debugging
		di "step_age=`dc_minpen_age_step'  pct_age=`dc_minpen_age_pct'  lvl_age=`dc_minpen_age_lvl'"
		di "step_yos=`dc_minpen_yos_step'  pct_yos=`dc_minpen_yos_pct'  lvl_yos=`dc_minpen_yos_lvl'"
		di "step_wg=`dc_minpen_wage_step'  pct_wg=`dc_minpen_wage_pct'  lvl_wg=`dc_minpen_wage_lvl'"
		di "base=`dc_minpen_base'  wage_thresh=`dc_minpen_wage'"
		

	
		// Variation by age
		tempvar minpen_age_dc
		generate `minpen_age_dc' = 0
		if `dc_minpen_age_step' > 0 & `dc_minpen_age_step' < . {
			*replace `minpen_age_dc' = min(max(`dc_minpen_age' - age, 0), `dc_minpen_age_max' - `dc_minpen_age')
			replace `minpen_age_dc' = min(max(age - `dc_minpen_age', 0), `dc_minpen_age_max' - `dc_minpen_age')
			replace `minpen_age_dc' = floor(`minpen_age_dc'  * `dc_minpen_age_step')
		}
		replace dc_pension_minpen = dc_pension_minpen * (1 + (`dc_minpen_age_pct' * `minpen_age_dc')) + (`minpen_age_dc' * `dc_minpen_age_lvl')

		// Variation by service time
		tempvar minpen_yos_dc
		generate `minpen_yos_dc' = 0
		if `dc_minpen_yos_step' > 0 & `dc_minpen_yos_step' < . {
			*replace `minpen_yos_dc' = min(max(`dc_minpen_yos' - yos, 0), `dc_minpen_yos_max' - `dc_minpen_yos')
			replace `minpen_yos_dc' = min(max(yos - `dc_minpen_yos', 0), `dc_minpen_yos_max' - `dc_minpen_yos')
			replace `minpen_yos_dc' = floor(`minpen_yos_dc' * `dc_minpen_yos_step')
		}
		replace dc_pension_minpen = dc_pension_minpen * (1 + (`dc_minpen_yos_pct' * `minpen_yos_dc')) + (`minpen_yos_dc' * `dc_minpen_yos_lvl')

		// Variation by wage
		tempvar minpen_wage_dc
		generate `minpen_wage_dc' = 0
		if `dc_minpen_wage_step' > 0 & `dc_minpen_wage_step' < . & `dc_minpen_wage' > 0 & `dc_minpen_wage' < . {
			replace `minpen_wage_dc' = min(max((reference_wage - `dc_minpen_wage') / `dc_minpen_wage', 0), (`dc_minpen_wage_max' - `dc_minpen_wage') / `dc_minpen_wage')
			replace `minpen_wage_dc' = floor(`minpen_wage_dc' * `dc_minpen_wage_step')
		}
		replace dc_pension_minpen = dc_pension_minpen * (1 + (`dc_minpen_wage_pct' * `minpen_wage_dc')) + (`minpen_wage_dc' * `dc_minpen_wage_lvl')



		
		// Maximum pension amount
		// Note: This allows for maximum pension amounts to scale with age and years of contributions
		replace dc_pension_maxpen = `dc_pension_max'
		replace dc_pension_maxpen = dc_pension_maxpen * (1 + (`dc_maxpen_age_scale' * max(age - `dc_maxpen_age_threshold', 0))) 
		replace dc_pension_maxpen = dc_pension_maxpen * (1 + (`dc_maxpen_yos_scale' * max(yos - `dc_maxpen_yos_threshold', 0)))
		

		***************
		// 	Compute the Value of the DC Pension benefit
		//	Convert DC account balance to monthly annuity
		//
		//	Annuity factor (AF): PV of 1 unit paid annually for T years at rate r.
		//	  AF = (1-(1+r)^(-T))/r  [r>0]   AF = T  [r=0]
		//	T = remaining life expectancy  (gender-specific).
		//
		//	Minimum pension guarantee: eligible retirees below dc_min_pension
		//	receive that floor (government tops up the difference).
		//	Ineligible retirees receive their balance as a lump sum.
	
		// Monthly pension = total balance / (12 months x annuity factor)
		replace dc_pension_benefit = dc_annuity if iacc > 0 & dc_annuity_factor > 0 & pension_class == 2
		replace dc_pension_benefit = 0 if missing(dc_pension_benefit)
		
		// Determine any givernment subsidy
		replace dc_gov_pension = max(dc_pension_minpen - dc_pension_benefit, 0) if dc_pension_elig == 1 & pension_class == 2
		
		// Register if person is eligible for the minimum DC pension
		replace minimum_pension = (dc_gov_pension > 0) if dc_pension_elig == 1 & pension_class == 2

		
		// Apply minimum and maximum pension amounts
		replace dc_pension_benefit = max(min(dc_pension_benefit, dc_pension_maxpen), dc_pension_minpen) if dc_pension_elig == 1 & pension_class == 2
		
		// No DC pension if not in the DC pension scheme
		replace dc_pension_benefit = 0 if pension_class != 2 						// No DC pension if not assigned to pension_class = 2 (DC pension type)
		replace dc_pension_benefit = 0 if pension_class == 2 & dc_pension_elig != 1 // No DC pension not eligible
		
	
		
		************************************************************************
		************************************************************************
		//	Stage 10 - Apply DB pension layers
		
		
	
		**********
		// Compute Reference Wages:
		// [TODO: Apply revalorization on reference wages]
		

		
		// Compute the reference wage
		// Note: This depends on the type of calculation
		// Note: We compute reference wages for DC plan members for comparability with DB plan members when computing replacement rates
		// 1 = Last N years before retirement: 
		if `ref_wage_type' == 1 {
			// Increment the reference wage
			// Seed from current wage on first working year when reference_wage is still missing (missing * scalar = missing in Stata, so EWMA can never self-recover)
			replace reference_wage = avg_db_covered_wage if missing(reference_wage) & !missing(avg_db_covered_wage) & pension_class == 1	// Seed for DB pensioners
			replace reference_wage = avg_dc_covered_wage if missing(reference_wage) & !missing(avg_dc_covered_wage) & pension_class == 2	// Seed for DC pensioners
			replace reference_wage = reference_wage * ((`ref_wage_n' - 1)/ `ref_wage_n') + (1 / `ref_wage_n') * avg_db_covered_wage if !missing(avg_db_covered_wage) & pension_class == 1	// For DB pensioners
			replace reference_wage = reference_wage * ((`ref_wage_n' - 1)/ `ref_wage_n') + (1 / `ref_wage_n') * avg_dc_covered_wage if !missing(avg_dc_covered_wage) & pension_class == 2	// For DC pensioners
			} //end if `ref_wage_type' == 1
		// 2 = Best N years in the career: Highest N wages in the career
		else if `ref_wage_type' == 2 {
			// Compare the lowest number 
			capture drop reference_wage
			egen reference_wage = rowmean(bestwage*)
			} //end if `ref_wage_type' == 2
		// 3 = Best N years within the last M years: Highest N wages within last M years before retirement
		// Note: This is the same as ref_wage_type = 2 above, but processed differently higher up
		else if `ref_wage_type' == 3 {
			capture drop reference_wage
			egen reference_wage = rowmean(bestwage*)
			} //end if `ref_wage_type' == 3
			
		
		
		
		**********
		// Determine DB pension eligibility [current year]:
		// Eligible for pension based on length of service
		replace db_pension_elig_mincont = ((los / 12) >= db_min_service_req)

		// Eligible for pension based on retirement age [current year]
		replace db_pension_elig_age = (age >= `db_retage_male')  if gender == 1
		replace db_pension_elig_age = (age >= `db_retage_female') if gender == 2
		
		// Eligible for pension based on early retirement restriction [current year]
		replace db_pension_elig_early = (age >= `db_retage_early_male')   if gender == 1
		replace db_pension_elig_early = (age >= `db_retage_early_female') if gender == 2
		
		// Eligible for a pension if you meet all of the eligibility criteria [current year]
		replace db_pension_elig = (db_pension_elig_mincont & (db_pension_elig_age | db_pension_elig_early)) if pension_class == 1
		
		
		


		
		**********
		// Determine pension benefit [current year]:
		
		// Years early (prior to retirement) [current year]
		replace db_years_early = max(`db_retage_male'   - age, 0) if gender == 1
		replace db_years_early = max(`db_retage_female' - age, 0) if gender == 2
		
		// Years late (after to retirement) [current year]
		replace db_years_late = max(age - `db_retage_male'  , 0) if gender == 1
		replace db_years_late = max(age - `db_retage_female', 0) if gender == 2
				

		**********
		// Pension replacement rate [current year]
		replace db_replacement_rate = min(yos * db_accrual_rate, db_standard_rate)					// Compute raw replacement rate 
		replace db_replacement_rate = db_replacement_rate - (db_years_early * db_early_penalty) 	// Apply early retirement penalties 
		replace db_replacement_rate = db_replacement_rate + (db_years_late * db_late_bonus) 		// Apply late retirement credits
		replace db_replacement_rate = max(min(db_replacement_rate, db_accrual_max), 0)				// Apply minimums and maximums

		

		**********
		//	Compute the minimum guarenteed pensions (minimum monthly amounts):
		//	Note: Minimum pension can differ by age, wage, and years of service (or the can be flat)
		//	Note: Some of the values are indexed earlier in the code
		replace db_pension_minpen = `db_minpen_base'

		// Debugging
		di "step_age=`db_minpen_age_step'  pct_age=`db_minpen_age_pct'  lvl_age=`db_minpen_age_lvl'"
		di "step_yos=`db_minpen_yos_step'  pct_yos=`db_minpen_yos_pct'  lvl_yos=`db_minpen_yos_lvl'"
		di "step_wg=`db_minpen_wage_step'  pct_wg=`db_minpen_wage_pct'  lvl_wg=`db_minpen_wage_lvl'"
		di "base=`db_minpen_base'  wage_thresh=`db_minpen_wage'"


		// Variation by age
		tempvar minpen_age_db
		generate `minpen_age_db' = 0
		if `db_minpen_age_step' != 0 {
			replace `minpen_age_db' = min(max(age - `db_minpen_age', 0), `db_minpen_age_max' - `db_minpen_age')
			replace `minpen_age_db' = floor(`minpen_age_db' * `db_minpen_age_step') 
		}
		replace db_pension_minpen = db_pension_minpen * (1 + (`db_minpen_age_pct' * `minpen_age_db')) + (`minpen_age_db' * `db_minpen_age_lvl')

		// Variation by service time
		tempvar minpen_yos_db
		generate `minpen_yos_db' = 0
		if `db_minpen_yos_step' != 0 {
			replace `minpen_yos_db' = min(max(yos - `db_minpen_yos', 0), `db_minpen_yos_max' - `db_minpen_yos')
			replace `minpen_yos_db' = floor(`minpen_yos_db' * `db_minpen_yos_step') 
		}
		replace db_pension_minpen = db_pension_minpen * (1 + (`db_minpen_yos_pct' * `minpen_yos_db')) + (`minpen_yos_db' * `db_minpen_yos_lvl')

		// Variation by wage
		tempvar minpen_wage_db
		generate `minpen_wage_db' = 0
		if `db_minpen_wage_step' != 0 & `db_minpen_wage' != 0 {
			replace `minpen_wage_db' = min(max((reference_wage - `db_minpen_wage') / `db_minpen_wage', 0), (`db_minpen_wage_max' - `db_minpen_wage') / `db_minpen_wage')
			replace `minpen_wage_db' = floor(`minpen_wage_db' * `db_minpen_wage_step')
		}
		replace db_pension_minpen = db_pension_minpen * (1 + (`db_minpen_wage_pct' * `minpen_wage_db')) + (`minpen_wage_db' * `db_minpen_wage_lvl')

		


		**********
		// Maximum pension amount
		// Note: This allows for maximum pension amounts to scale with age and years of contributions
		replace db_pension_maxpen = `db_pension_max'
		replace db_pension_maxpen = db_pension_maxpen * (1 + (`db_maxpen_age_scale' * max(age - `db_maxpen_age_threshold', 0)))
		replace db_pension_maxpen = db_pension_maxpen * (1 + (`db_maxpen_yos_scale' * max(yos - `db_maxpen_yos_threshold', 0))) 
		
		
		**********
		// Compute the pension benefit [current year]:
		// Pension_(base,i) = ReferenceWage_i ∑_(t=1)^(YearsofService(r))▒〖AccrualRate〗_i (t)
		replace db_pension_benefit_base = reference_wage * db_replacement_rate * db_pension_elig if pension_class == 1
		
		//	Apply pension minimums and maximums
		replace db_pension_benefit = max(min(db_pension_benefit_base, db_pension_maxpen), db_pension_minpen) * db_pension_elig if pension_class == 1
		replace db_pension_benefit = 0 if pension_class != 1 						// No DB pension if not assigned to pension_class = 1 (DB pension type)
		replace db_pension_benefit = 0 if pension_class == 1 & db_pension_elig != 1 // No DB pension not eligible
		
		
		************************************************************************
		// Expected pension value next year
		
		********** 
		// Years of service [expected, next year]
		*replace yos_next = yos + (contribution_density)	
		replace yos_next = yos + 1

		
		**********
		// Determine DB pension eligibility [expected, next year]:
		
		// Eligible for pension based on length of service [expected, next year]
		replace db_pension_elig_mincont_next = (yos_next >= db_min_service_req)

		// Eligible for pension based on retirement age [expected, next year]
		replace db_pension_elig_age_next = ((age + 1) >= `db_retage_male')  if gender == 1
		replace db_pension_elig_age_next = ((age + 1) >= `db_retage_female') if gender == 2
		
		// Eligible for pension based on early retirement restriction [expected, next year]
		replace db_pension_elig_early_next = ((age + 1) >= `db_retage_early_male')   if gender == 1
		replace db_pension_elig_early_next = ((age + 1) >= `db_retage_early_female') if gender == 2
		
		// Eligible for a pension if you meet all of the eligibility criteria [expected, next year]
		replace db_pension_elig_next = (db_pension_elig_mincont_next & (db_pension_elig_age_next | db_pension_elig_early_next))
		
		
		**********
		// Determine pension benefit [expected, next year]:

		// Years early (prior to retirement) [expected, next year]
		replace db_years_early_next = max(`db_retage_male'   - (age + 1), 0) if gender == 1
		replace db_years_early_next = max(`db_retage_female' - (age + 1), 0) if gender == 2
		
		// Years late (after to retirement) [expected, next year]
		replace db_years_late_next = max((age + 1) - `db_retage_male'  , 0) if gender == 1
		replace db_years_late_next = max((age + 1) - `db_retage_female', 0) if gender == 2
		
		
		// Pension replacement rate [current year]
		replace db_replacement_rate_next = min(yos_next * db_accrual_rate, db_standard_rate)				// Compute raw replacement rate 
		replace db_replacement_rate_next = db_replacement_rate_next - (db_years_early * db_early_penalty) 	// Apply early retirement penalties 
		replace db_replacement_rate_next = db_replacement_rate_next + (db_years_late * db_late_bonus) 		// Apply late retirement credits
		replace db_replacement_rate_next = max(min(db_replacement_rate_next, db_accrual_max), 0)			// Apply minimums and maximums
		
		
		**********
		// Compute the pension benefit [expected, next year]:
		// Pension_(base,i) = ReferenceWage_i ∑_(t=1)^(YearsofService(r))▒〖AccrualRate〗_i (t)
		replace db_pension_benefit_base_next = reference_wage * db_replacement_rate_next * db_pension_elig_next if pension_class == 1
		
		//	Apply pension minimums and maximums
		replace db_pension_benefit_next = max(min(db_pension_benefit_base_next, db_pension_maxpen), db_pension_minpen) * db_pension_elig_next
		replace db_pension_benefit_next = 0 if pension_class != 1 								// No DB pension if not assigned to pension_class = 1 (DB pension type)
		replace db_pension_benefit_next = 0 if pension_class == 1 & db_pension_elig_next != 1 	// No DB pension not eligible
		
		
	
		
		************************************************************************
				

		**********
		// Defined Benefit
		// Index pension benefit amounts 
		// This includes: base pension, reference wage, minimum and maximum pensions
		
		// Minimum pension index rate 
		local mpi_rate = ( `db_mpi_inflation_coeff' * `pindex_inflation' ///
					     + `db_mpi_realwage_coeff'  * `pindex_realwage'  ///
					     + `db_mpi_anchor_coeff'    * `pindex_anchor') / 100
		replace debug_mpi_rate = `mpi_rate'

		// Update related pension amounts
		local db_minpen_base    	= `db_minpen_base'    	* (1 + `mpi_rate')
		local db_minpen_refwage 	= `db_minpen_refwage' 	* (1 + `mpi_rate')
		local db_minpen_wage		= `db_minpen_adj1' 		* `db_minpen_refwage'	
		local db_minpen_wage_max	= `db_minpen_adj2' 		* `db_minpen_refwage'	 
		local db_pension_max     	= `db_pension_max' 		* (1 + `mpi_rate')
		local db_covered_wage_max 	= `db_covered_wage_max' * (1 + `mpi_rate')
		local db_covered_wage_min 	= `db_covered_wage_min' * (1 + `mpi_rate')
	
		
		
		**********
		// Defined Contribution
		// Index pension benefit amounts (by assumed wage growth) 
		// This includes: base pension, reference wage, minimum and maximum pensions

		// Update related pension amounts
		local dc_minpen_base          = `dc_minpen_base'      * (1 + `wage_growth_user')
		local dc_minpen_refwage       = `dc_minpen_refwage'   * (1 + `wage_growth_user')
		local dc_minpen_wage          = `dc_minpen_adj1' 	  * `dc_minpen_refwage'
		local dc_minpen_wage_max      = `dc_minpen_adj2'      * `dc_minpen_refwage'
		local dc_minpen_age_lvl       = `dc_minpen_age_lvl'   * (1 + `wage_growth_user')
		local dc_minpen_yos_lvl       = `dc_minpen_yos_lvl'   * (1 + `wage_growth_user')
		local dc_minpen_wage_lvl      = `dc_minpen_wage_lvl'  * (1 + `wage_growth_user')
		local dc_pension_max     	  = `db_pension_max'      * (1 + `wage_growth_user')
		local dc_covered_wage_max 	  = `dc_covered_wage_max' * (1 + `wage_growth_user')
		local dc_covered_wage_min 	  = `dc_covered_wage_min' * (1 + `wage_growth_user')
	
		


		************************************************************************
		************************************************************************
		//	Stage 11 - Retirement decision
		//	Note: People retire if they have enough contributions to retire and are eligible
		//	If there is a benefit to working longer, they will work longer
		// [TODO: Replace this with a decision that reflects net present value of a pension and life expectancy]
		// [TODO: Talk to Marola about how to model retirement decision]
		// [TODO: Reorganize the DB and DC pension sections so that we calculated DB then DC and then Retirement decisions]
		
		
		// Step 1: Annuity factor at current age
		// PV of $1/year for remaining life expectancy
		local r_db_adj = max(`db_discount_rate' - `mpi_rate', 0.001)
		replace db_annuity_factor 		= (1 - ((1 + `mpi_rate') / (1 + `db_discount_rate'))^(-life_expectancy)) 		/ `r_db_adj'
		replace db_annuity_factor_next  = (1 - ((1 + `mpi_rate') / (1 + `db_discount_rate'))^(-(life_expectancy - 1)))	/ `r_db_adj'

		
		// Step 2: Pension wealth TODAY
		// Generate indicator of pension wealth
		replace pension_wealth = iacc   if pension_class == 2
		replace pension_wealth = db_pension_benefit * db_annuity_factor if pension_class == 1


		// Step 3: Pension wealth ONE YEAR FROM NOW
		// DC: balance grows + one year of contributions (scaled by density)
		replace pension_wealth_next = ( iacc * (1 + `dc_net_return') + contribution_density * dc_contributions) if pension_class == 2
		// DB: one more year of accrual, but annuity factor falls (older at retirement)
		replace pension_wealth_next = db_pension_benefit_next * db_annuity_factor_next if pension_class == 1


		// Step 4: Accrual and implicit tax rate
		// Annual pension benefit if retiring now
		replace benefit_now = (iacc / dc_annuity_factor) * dc_pension_elig	if pension_class == 2	// DC pension plan
		replace benefit_now = (db_pension_benefit)       * db_pension_elig 	if pension_class == 1	// DB pension plan
		// Pension wealth Accrual = gain in pension wealth - foregone pension payment
		replace pension_accrual     = pension_wealth_next - pension_wealth - benefit_now
		// Implicit tax rate (Gruber-Wise: normalised by annual earnings)
		replace implicit_tax = -pension_accrual / (reference_wage * 12) 


		// Step 5: Apply Tax-threshold rule
		// Apply Tax-threshold rule
		// Calibrate tau_star so that median simulated retirement age
		// matches median observed retirement age from your pensioner file
		*local tau_star = 0.10   // Starting value: retire when pension system taxes >10% of earnings
		replace  pension_elig = dc_pension_elig if pension_class == 2
		replace  pension_elig = db_pension_elig if pension_class == 1

		// Flag: Working longer is an implicit tax on earnings (potential) and so it is better to retire
		replace retire_on_tax = ( implicit_tax > 0 & !missing(implicit_tax) & retirement_age == 1 & status == 1 & pension_elig == 1 )

		// Apply the retirmeent rule (if not dead)
		replace status = 2 if retire_on_tax == 1 & status != 99

		// People who are too old to retire, then take pseudo retirement (and maybe get a lumpsum)
		replace status = 2 if age >= `too_old_to_retire'
		
		// People who have no hope of retiring by the too-old-age retire now as well
		replace status = 2 if los_gap > ((`too_old_to_retire' - age) * 12)
		
		
		
		
		************************************************************************		
		

		
// 		// Rough rule: DB pensioners retire if eligible and if hit the maximum replacement rate (or are too old) and are not dead (status == 99)
// 		// Note: No early retirement right now
// 		replace status = 2 if db_pension_elig_mincont & db_pension_elig_age &  db_replacement_rate >= `db_accrual_max' & status != 99 & pension_class == 1
//		
// 		// Rough rule: DC pensioners retire when reaching retiremen age and having the minimum contributions (no early retirement for now)
// 		replace status = 2 if dc_pension_elig_age & dc_pension_elig_mincont & status != 99 & pension_class == 2
//		
// 		// People who are too old to retire, then take pseudo retirement (and maybe get a lumpsum)
// 		replace status = 2 if age >= `db_too_old_to_retire'
//		
		// Update value for DB pension government subsidy
		replace db_gov_pension = max(db_pension_minpen - db_pension_benefit_base, 0) if status == 2 & db_pension_elig & pension_class == 1
		
		// Register if person is eligible for the minimum DB pension
		replace minimum_pension = (db_gov_pension > 0) if status == 2 & db_pension_elig & pension_class == 1

		
		// Record the month and year of retirement
		// [TODO: Currently people retire at end of the year, we may change this]
		replace retire_year  = `yr' if status == 2
		replace retire_month = 12   if status == 2  
		
		// Compute lump-sum amounts for those who retire but are not eligible
		*replace pension_lumpsum = 0 if `db_lumpsum_flag' == 1
		
		
		*******************
		// Approximate calculation of lump-sum amounts
		// Ineligible retirees: withdraw balance as lump sum, no annuity
		replace dc_pension_benefit  = 0    if status == 2 & dc_pension_elig != 1
		replace db_pension_benefit  = 0    if status == 2 & db_pension_elig != 1
		replace pension_lumpsum = max(pension_lumpsum, iacc) if status == 2 & !dc_pension_elig & !db_pension_elig & iacc > 0

		// [TODO: Fix this calculation to make it generic]
		replace pension_lumpsum = los * avg_db_covered_wage * `db_contribution_rate_ee' * (1 + `db_lumpsum_interest')^yos if pension_class == 1 & `db_lumpsum_flag' & !db_pension_elig & status == 2	// DB plan
		replace pension_lumpsum = iacc if pension_class == 2 & !dc_pension_elig & status == 2	// DC plan
		replace gets_lumpsum = (dc_pension_elig != 1 & db_pension_elig != 1 & pension_lumpsum > 0 & !missing(pension_lumpsum))



		************************************************************************
		************************************************************************
		//	Stage 13 - In-year reporting
		// 	Note: Because we drop all of the years as we process them, we need to collect all of our reporting as we go

		// Generate tempfiles
		tempfile rpt_age_sex_decile_dens_inyear

		tempfile rpt_sex_decile_dens_inyear
		tempfile rpt_age_sex_decile_inyear
		tempfile rpt_age_sex_dens_inyear
		tempfile rpt_age_decile_dens_inyear
		
		tempfile rpt_age_decile_inyear
		tempfile rpt_age_sex_inyear
		tempfile rpt_age_dens_inyear
		tempfile rpt_sex_decile_inyear
		tempfile rpt_sex_dens_inyear
		tempfile rpt_decile_dens_inyear
		
		tempfile rpt_age_inyear
		tempfile rpt_decile_inyear
		tempfile rpt_sex_inyear
		tempfile rpt_dens_inyear
		tempfile rpt_total_inyear
		


		
		// Generate status totals
		*capture drop  affiliated
		capture drop  retired
		capture drop  disabled
		capture drop  widowed
		capture drop  deceased
		capture drop  num_new_affiliates
		capture drop  num_exiters
		capture drop  num_reentrants
		capture drop  num_affiliates
		capture drop  num_contributors
		capture drop  num_inactive
		capture drop  target_employment_rate
		capture drop  target_turnover_rate
		capture drop  population_total

		*generate affiliated  		= weight * (status == 1)
		generate retired     		= weight * (status == 2)
		generate disabled    		= weight * (status == 3)
		generate widowed     		= weight * (status == 4)
		generate deceased    		= weight * (status == 99)
		generate num_new_affiliates = weight * new_affiliate
		
		
		
		***************
		// Alternate (and faster) version of the code
		// More detailed aggregates for these states as they are not persistent
		// Step 1: pre-generate indicators (needed because gcollapse takes variable names, not expressions)
		tempvar _alive _contrib _inactive
		generate `_alive'    = (status != 99)
		generate `_contrib'  = (dens == 1 & status != 99)
		generate `_inactive' = (dens == 0 & status != 99)

		// Step 2: collapse to id-level totals in a single pass
		preserve
			keep if month > 0         
			gcollapse (sum) num_exiters=exiter     ///
							num_reentrants=reentrant  ///
							num_affiliates=`_alive'   ///
							num_contributors=`_contrib' ///
							num_inactive=`_inactive'  ///
					  , by(id)
			tempfile id_agg_yr
			save `id_agg_yr', replace
		restore

		// Step 3: join back onto the full 13-month dataset
		join num_exiters num_reentrants num_affiliates num_contributors num_inactive, from(`id_agg_yr') by(id) keep(1 3) nogenerate

		// Step 4: apply weights and scaling
		replace num_exiters      = weight * num_exiters
		replace num_reentrants   = weight * num_reentrants
		replace num_affiliates   = weight * num_affiliates   / 12
		replace num_contributors = weight * num_contributors / 12
		replace num_inactive     = weight * num_inactive     / 12
		
		***************
		// Report on targets
		generate target_employment_rate = 100 * `target_emp_rate'
		generate target_turnover_rate	= `turnover_target'
		
		// Join in the total population data
		capture drop pop
		capture drop working_age
		capture drop population_total
		capture drop working_age_total
		join pop working_age, from(`population_db_total') by(year) keep(1 3) nogenerate	// ftools version of merge [faster]
		rename pop population_total
		rename working_age working_age_total
		

		
		// Reporting locals
		local sumvars  		= "num_new_affiliates num_exiters num_reentrants num_affiliates num_contributors num_inactive retired disabled widowed deceased samplesize=weight"
		local meanvars_tot 	= "population_total working_age_total avg_age=age los loa wage contribution_density target_employment_rate target_turnover_rate"
		local meanvars 		= "los loa wage contribution_density"
		local var_order		= "year age gender wage_decile dens samplesize num_affiliates num_contributors num_inactive num_new_affiliates num_exiters num_reentrants retired disabled widowed deceased los loa wage contribution_density"

 
 
		
	
		***************
		// In-year reporting by age, decile, gender, and contribution status:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile, gender, and contribution status
			collapse (sum) `sumvars' (mean) `meanvars', by(age gender wage_decile dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_sex_decile_dens_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by age, gender, and wage decile:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile, gender, and contribution status
			collapse (sum) `sumvars' (mean) `meanvars', by(gender wage_decile age)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate dens = 99 	// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_sex_decile_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by decile, age, and contribution status:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile, gender, and contribution status
			collapse (sum) `sumvars' (mean) `meanvars', by(age wage_decile dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate gender = 99 	// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_decile_dens_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by age, gender, and contribution status:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile, gender, and contribution status
			collapse (sum) `sumvars' (mean) `meanvars', by(gender age dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate wage_decile = 99 	// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_sex_dens_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by decile, gender, and contribution status:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile, gender, and contribution status
			collapse (sum) `sumvars' (mean) `meanvars', by(gender wage_decile dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate age = 999			// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_sex_decile_dens_inyear', emptyok replace
		restore
			
				
		***************
		// In-year reporting by decile and age:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile and gender
			collapse (sum) `sumvars' (mean) `meanvars', by(age wage_decile)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate dens = 99 			// Totals placeholder
			generate gender = 99		// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_decile_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by age and gender:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile and gender
			collapse (sum) `sumvars' (mean) `meanvars', by(gender age)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate dens = 99 			// Totals placeholder
			generate wage_decile = 99	// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_sex_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by age and contribution density:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile and gender
			collapse (sum) `sumvars' (mean) `meanvars', by(age dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate gender = 99 		// Totals placeholder
			generate wage_decile = 99	// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_dens_inyear', emptyok replace
		restore
		

			
		***************
		// In-year reporting by decile and gender:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile and gender
			collapse (sum) `sumvars' (mean) `meanvars', by(gender wage_decile)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate dens = 99 			// Totals placeholder
			generate age = 999			// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_sex_decile_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by decile and contribution status:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile and contribution status
			collapse (sum) `sumvars' (mean) `meanvars', by(wage_decile dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate gender = 99 	// Totals placeholder
			generate age = 999		// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile and density
			save `rpt_decile_dens_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting by gender and contribution status:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by gender and contribution status
			collapse (sum) `sumvars' (mean) `meanvars', by(gender dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate wage_decile = 99 	// Totals placeholde
			generate age = 999			// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By gender and density
			save `rpt_sex_dens_inyear', emptyok replace
		restore
		
		
		
		
		***************
		// In-year reporting by age:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile and gender
			collapse (sum) `sumvars' (mean) `meanvars', by(age)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate gender = 99		// Totals placeholder
			generate dens = 99 			// Totals placeholder
			generate wage_decile = 99	// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_age_inyear', emptyok replace
		restore

		
		***************
		// In-year reporting by decile:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by decile and gender
			collapse (sum) `sumvars' (mean) `meanvars', by(wage_decile)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate gender = 99	// Totals placeholder
			generate dens = 99 		// Totals placeholder
			generate age = 999		// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_decile_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting totals by gender:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by gender
			collapse (sum) `sumvars' (mean) `meanvars', by(gender)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate wage_decile = 99 	// Totals placeholder
			generate dens = 99 			// Totals placeholder
			generate age = 999			// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save by gender
			save `rpt_sex_inyear', emptyok replace
		restore
				
			
		***************
		// In-year reporting by contribution status:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by contribution status
			collapse  (sum) `sumvars' (mean) `meanvars', by(dens)
			// Generate placeholders (for appending)
			generate year = `yr'
			generate gender = 99 		// Totals placeholder
			generate wage_decile = 99 	// Totals placeholder
			generate age = 999			// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate 		= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order `var_order'
			// Save By decile
			save `rpt_dens_inyear', emptyok replace
		restore
		
		
		***************
		// In-year reporting totals:
		preserve
			// Keep just the last month of the year
			keep if month == 12
			// Collapse by gender
			collapse (sum) `sumvars' (mean) `meanvars_tot'
			// Generate placeholders (for appending)
			generate year = `yr'
			generate gender = 99 		// Totals placeholder
			generate wage_decile = 99 	// Totals placeholder
			generate dens = 99 			// Totals placeholder
			generate age = 999			// Totals placeholder
			// Compute employment rate and turnover rate
			generate employment_rate 	= 100 * num_contributors / num_affiliates						// "Employment rate": Share of affiliates who are working
			generate turnover_rate	 	= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)	// Share of people changing roles each year: (exiters + reentrants) / affiliates
			// Order the variables
			order year age gender wage_decile dens  							///
			samplesize num_affiliates num_contributors num_inactive 			/// 
			num_new_affiliates num_exiters num_reentrants  						///
			retired disabled widowed deceased  									///
			avg_age los loa wage contribution_density 							///
			population_total working_age_total 							 		/// 
			target_employment_rate employment_rate								///
			target_turnover_rate turnover_rate
			// Save totals
			save `rpt_total_inyear', emptyok replace
		restore
		
		
		***************
		// Accumulate in-year reporting into reporting database - total
		preserve
			use `inyear_affiliate_reporting_tot', clear
			append using `rpt_total_inyear'
			save `inyear_affiliate_reporting_tot', replace
		restore
		
		
		***************
		// Accumulate in-year reporting into reporting database - breakdowns
		preserve
			use `inyear_affiliate_reporting', clear
			append using `rpt_age_sex_decile_dens_inyear'
			
			append using `rpt_sex_decile_dens_inyear'
			append using `rpt_age_sex_decile_inyear'
			append using `rpt_age_decile_dens_inyear'
			
			append using `rpt_age_decile_inyear'
			append using `rpt_age_sex_inyear'
			append using `rpt_age_dens_inyear'
			append using `rpt_sex_decile_inyear'
			append using `rpt_sex_dens_inyear'
			append using `rpt_decile_dens_inyear'
			
			append using `rpt_age_inyear'
			append using `rpt_decile_inyear'
			append using `rpt_dens_inyear'
			append using `rpt_sex_inyear'

			save `inyear_affiliate_reporting', replace
		restore
				


		
		************************************************************************
		************************************************************************
		//	Stage 14 - Save database of affiiates transitioning to be pension beneficiaries (i.e those retiring)
		// Carve off the pensioners into a storage location (for appending later on to the pensioners basecase)
		preserve
			//	Note: Needs to contain the following variables:
			//		- pension_benefit [Monthly pension benefit]
			//		- age 				[Age of recipient]
			//		- gender 			[Gender of recipient, 1 = male, 2 = female]
			//		- startyear 		[Year pension started being paid]
			//		- pension_class 	[Class of pension (e.g., 1=DB, 2=DC, etc.)]
			//		- pension_type 		[Type of pension (old-age, disability, surivior)]
			//		- pension_id		[Pension unique ID number]
			tempfile pensioners`yr'
			keep if status == 2		// Status 2 = retired
			keep if month == retire_month	
			
			// Record the age and wage at retirement
			generate age_retired = age
			generate wage_retired = wage_ref	// Wage (or reference wage) at retirement
			replace  wage_retired = wage if !missing(wage)	// Final update of referenc wage before retirement
			
			// Generate indicator of wage_decile at retirement
			xtile wage_decile_ret = wage_ref, nq(10)

			// Generate the pension-specific variables 
			generate startyear = `yr'
			*generate pension_class = 1 	// Pension class = Defined Benefit (DB)
			// [TODO: Return to pension_type when adding in other pension types]
			generate pension_type = 1 	// Pension type = old-age (1)
			generate pension_id = 1   	// Pension system unique ID
			rename id affiliate_id
			// Distinguish from base-year observed pensioners
			generate pensioner_source = "projected"   
			// Combine pension benefits into a single pension_benefit variable
			capture drop pension_benefit
			generate pension_benefit = db_pension_benefit + dc_pension_benefit
			replace  pension_benefit = . if gets_lumpsum == 1
			// Compute some pension statistics at time of retirement (replacement rate and income adequacy)
			generate replacement_rate = 100 * pension_benefit / reference_wage 	// Pension replacement rate 
			replace  replacement_rate = . if gets_lumpsum == 1
			*generate replacement_rate = 100 * pension_benefit / reference_wage if pension_class == 1	// Pension replacement rate - DB pension
			*replace  replacement_rate = 100 * pension_benefit / wage_retired if pension_class == 2	// Pension replacement rate - DC pension
			generate income_adequacy  = 100 * pension_benefit /  average_wage		// Pensions are a share of average wage
			replace  income_adequacy = . if gets_lumpsum == 1
			


			// Compute the value of any government subsidies (minimum pension top ups)
			replace db_gov_pension = 0 if missing(db_gov_pension)
			replace dc_gov_pension = 0 if missing(dc_gov_pension)
			generate gov_minpen_subsidy = db_gov_pension + dc_gov_pension
			// Keep only the key reporting variables
			keep age age_retired gender startyear pension_class pension_type ///
				 pension_id weight year affiliate_id yob loa los contribution_density iacc wage_decile wage_decile_ref status ///
				 reference_wage  average_wage db_years_early db_years_late db_replacement_rate ///
				 retire_year deathyear deathmonth ///
				 db_pension_benefit db_pension_minpen db_pension_maxpen db_gov_pension ///
				 dc_pension_benefit dc_pension_minpen dc_pension_maxpen dc_gov_pension dc_annuity_factor ///
				 pension_benefit gov_minpen_subsidy pension_lumpsum pensioner_source replacement_rate income_adequacy ///
				 minimum_pension life_expectancy wage wage_ref wage_retired gets_lumpsum ///
				 debug_wage_growth_user debug_db_revalorization_rate debug_mpi_rate wage_decile_ret
			save `pensioners`yr''
			noisily display " "
			noisily display "Pensioners in `yr' saved to a separate file"
		restore
	
		// Save in-year dataset for appending later (if extended_output flag is toggled)
		// Note: We compile these datasets on
		if `extended_output' == 1 {
			// Save a copy of the existing database
			tempfile affiliate_sim`yr'
			save `affiliate_sim`yr'', replace
			} // end if extended_output
		
		
		//	Cleanup variables that we will redefine 
		capture drop __00*	// Drop tempvars

		
		// Drop pensioners (they are no longer affiliates)
		drop if status == 2
		
		// Drop people who have died
		// Once the disability/survivor stage is active, deceased affiliates must be accessible
		// to determine which survivors become widows/widowers. Replace the drop with:
		// preserve
		//     keep if status == 99
		//     tempfile deceased_affiliates`yr'
		//     save `deceased_affiliates`yr'', replace   // Available for survivor processing
		// restore
		// drop if status == 99   // Still drop from main simulation dataset
		// Alternatively, carry the deceased for one additional year with a flag, then drop them the
		// following year after survivor transitions have been applied.
		drop if status == 99
	

	
	} // end forvalues yr	 
	****************************************************************************
	****************************************************************************
	****************************************************************************
	****************************************************************************
	****************************************************************************

//	Compress the dataset (for size constraints)
	compress, nocoalesce

********************************************************************************
//	Final reporting on the affiliate database
	// Keep only the latest observation in a year
	keep if month == 12
	
	// Clean up tempvars before saving
	capture drop __00*
	
	// Move all the annual wage variables to the back
	*order wage_????, last
	
	
	// Export the data
	*cd "`outdir'"
	export delimited using "`outdir'\1_PROSTv2-`simname'-Affiliates-`startyear'-`endyear'.csv", replace
	save "`outdir'\1_PROSTv2-`simname'-Affiliates-`startyear'-`endyear'.dta", replace



	// [Sanity check: Output histograms of contribution density by decile]
	// Save histogram to compare with simulated density in the last year
	if `histograms' == 1 {
		histogram contribution_density if month == 12, name(cod_lastyear, replace) yscale(range(0 5))
		graph combine cod_baseyear cod_lastyear, name(aggregate, replace) ycommon
		
		histogram contribution_density if month == 12 & !missing(new_affiliate_flag), name(cod_lastyear_new, replace) yscale(range(0 5)) 
		graph combine cod_baseyear cod_lastyear_new, name(aggregate_new, replace) ycommon
		
		histogram contribution_density if month == 12, by(wage_decile) name(cod_by_decile_lastyear, replace) yscale(range(0 15))
		graph combine cod_by_decile_baseyear cod_by_decile_lastyear, name(by_decile, replace) ycommon
		
		histogram contribution_density if month == 12 & !missing(new_affiliate_flag), by(wage_decile) name(cod_by_decile_lastyear_new, replace) yscale(range(0 15))
		graph combine cod_by_decile_baseyear cod_by_decile_lastyear_new, name(by_decile_new, replace) ycommon
		

		} // end if histograms

	
	
	
********************************************************************************
//	Export EXTENDED OUTPUT in-year affiliate reporting
	if `extended_output' == 1 {
		// Open the database
		use `extended_output_data', clear

		// Append it to the extended output database 
		forvalues yr = `startyear'/`endyear' {
			append using `affiliate_sim`yr''
			}
		
		// Clean up tempvars before saving
		capture drop __00*
		
		// Export dataset
		*cd "`outdir'"
		save "`outdir'\1_PROSTv2-`simname'-EXTENDED-OUTPUT.dta", replace
		} // end if extended_output
	

	

	
	

********************************************************************************
//	Pensioners projection
//	After working through the affiliate database we save the pensioners by year
//	and merge it into the pension database to get the database of pensioners
//	We then project that forward

//	Load the baseyear pensioners database
//	Note: Contains the following variables:
//		- pension_benefit   [Monthly pension benefit]
//		- age 				[Age of recipient]
//		- gender 			[Gender of recipient, 1 = male, 2 = female]
//		- startyear 		[Year pension started being paid]
//		- pension_class 	[Class of pension (e.g., DB, DC, etc.)]
//		- pension_type 		[Type of pension (old-age, disability, surivior)]
//		- pension_id		[Pension unique ID number]
	use `pensioners_database', clear	

//	Sample a share of the baseyear individuals to be our projection database
//	[TODO: Consider a stratified sample]
//	Skip if the synthetic data was already sampled externally (presampled == 1).
	if `presampled' == 0 {
		sample `samplesize'
		capture drop weight
		generate weight = 100 / `samplesize'
	}
	// If pre-sampled: weight already exists in the data with the correct value; nothing to do.
	
//	Add in the year	
	capture drop year
	generate year = `baseyear'
	
//	Add in a pensioner unique ID number
	capture drop pensioner_id
	generate pensioner_id = _n
	
//	Inlcude a pensioner source (observed / projected)
	generate pensioner_source = "observed"
	
//	Add in a status (in the base year it is all 2 = retired)
//	[TODO: Revisit this when adding in disabilty and survivor]
	capture drop status
	generate status = 2 // 2 = retired
	
//	Add a variable of age at death (for calculating life expectancy)
	capture drop age_died
	generate age_died = .
	
//	Generate an age group indicator
	capture drop age_grp
	generate age_grp = floor(age / 5) * 5
	
//	Add variable capturing if a person died this year
	capture drop died_flag
	generate died_flag = 0
	
//	Reporting placeholders
	generate pension_index = 0		// Annual indexation parameter (user defined)
	generate replacement_rate = .	// Income replacement rate (pension benefit / individual's pre-retirement wage)
	generate income_adequacy = .	// Income adequacy metric (pension benefit / average wage)

//	DC pension: initialise if not already present in the base-year pensioner file
//	(base-year observed pensioners may not have a dc_pension_benefit field; new retirees
//	from the affiliate loop do, having been set in Stage 9.5)
	capture generate dc_pension_benefit = 0
	replace  dc_pension_benefit = 0 if missing(dc_pension_benefit)
	replace  dc_pension_benefit = pension_benefit if pension_class == 2 	// 2 = DC plan
	
//	DB pension: initialise if not already present in the base-year pensioner file	
	capture generate db_pension_benefit = 0
	replace  db_pension_benefit = 0 if missing(db_pension_benefit)
	replace  db_pension_benefit = pension_benefit if pension_class == 1 	// 1 = DB plan
	


	

//	Pensioners: Loop over the projection period
	forvalues yr = `startyear'/`endyear' {
		// Save the last row of the dataset for later (when adding new ID numbers)
		local last_pensioner_row = _N

		//	Resolve indexation coefficients for this year (carry-forward)
		local yr_db_index = min(`yr', `db_index_max_year')
		local alpha1 = `db_alpha1_`yr_db_index''
		local alpha2 = `db_alpha2_`yr_db_index''
		local alpha3 = `db_alpha3_`yr_db_index''

	
		
		************************************************************************
		************************************************************************
		// Stage 1: Append years pensioners
		append using `pensioners`yr''
		
		// Give new pensioners a new id number
		summarize pensioner_id, meanonly
		local max_pensioner_id = r(max)
		replace pensioner_id = `max_pensioner_id' + (_n - `last_pensioner_row') if missing(pensioner_id)
		
		// Reset died_flag to zero
		replace died_flag = 0
		
		// Compute pension adequacy metrics
		// [TODO: Discuss whetehr we want to update each year - we will need to index reference_wage and  average_wage]
// 		replace replacement_rate = 100 * pension_benefit / reference_wage 	// Income replacement rate (pension benefit / reference wage)
// 		replace income_adequacy  = 100 * pension_benefit /  average_wage 		// Income adequacy metric (pension benefit / average wage)

		
		************************************************************************
		************************************************************************
		// Stage 2: Apply mortality rates	
		
		// 	Merge in mortality data
		noisily display " "
		noisily display "Merging in mortality rates..."
		capture drop mortality
		// Cap merge year so projection years beyond data use the last available rates
		capture drop year_merge
		generate year_merge = min(year, `mortality_max_year')
		join mortality, from(`mortality_database') by(gender age year_merge) keep(1 3) nogenerate	// ftools version of merge [faster]
		drop year_merge

		// Sample probability of dying
		tempvar randnum_mortality
		generate `randnum_mortality' = runiform()
		
		// Assign mortality
		replace died_flag = 1 		if mortality > `randnum_mortality' & status != 99
		replace deathyear = `yr'	if died_flag == 1 // Record year died
		*replace status = 99 		if died_flag == 1 // Status 99 means dead
		
		// Housekeeping for dead people
		replace db_pension_benefit 	= . if died_flag == 1
		replace dc_pension_benefit 	= . if died_flag == 1
		replace pension_benefit 	= . if died_flag == 1
		replace age_died = age 		    if died_flag == 1
	
	
	
		************************************************************************
		************************************************************************
		// Stage 3: Index pension benefits and reference wages
		// After retirement, the pension evolves according to the indexation rule.
		// Pension_i (t) = Pension_i (t-1) * (1+PensionIndexationRate(t))
		// PensionIndexationRate(t) = α_1 * Inflation(t-1) + α_2 * RealWageGrowth(t-1) + α_3 * AnchorVariable(t)
		
		capture drop pindex_inflation pindex_realwage pindex_anchor
		// Cap merge year so projection years beyond data use the last available indexation values
		capture drop year_merge
		generate year_merge = min(year, `indexation_max_year')
		join pindex_inflation pindex_realwage pindex_anchor, from(`indexation_database') by(year_merge) keep(1 3) nogenerate
		drop year_merge
		quietly summarize pindex_inflation
		local pindex_inflation = r(mean)
		quietly summarize pindex_realwage
		local pindex_realwage  = r(mean)
		quietly summarize pindex_anchor
		local pindex_anchor    = r(mean)

		replace pension_index = ( `alpha1' * `pindex_inflation' 	///
								+ `alpha2' * `pindex_realwage' 		///
								+ `alpha3' * `pindex_anchor') / 100
		replace db_pension_benefit = db_pension_benefit * (1 + pension_index)

		// DC pension indexation (applied only if dc_annuity_indexed == 1)
		if `dc_annuity_indexed' {
			replace dc_pension_benefit = dc_pension_benefit * (1 + pension_index) if dc_pension_benefit > 0
		}
		
		//	Update the overall pension benefit
		replace pension_benefit = dc_pension_benefit + db_pension_benefit
		replace pension_benefit = . if gets_lumpsum == 1



		************************************************************************
		************************************************************************
		// Stage 4: In-year reporting
		
		// 	Outputs to report on:
		//
		// 	Average Age of Disabled Beneficiaries (by year, by sex) 
		// 	Total Number of Old Age Retirees (by year, by sex) 
		// 	Total Number of Survivors (by year, by sex) 
		// 	Total Number of Disabled Beneficiaries (by year, by sex) 
		// 	Retirees (by age and sex, by year) 
		// 	Survivors (by age and sex, by year) 
		// 	Disabled Beneficiaries (by age and sex, by year) 
		
		
		// Generate tempfiles
		tempfile pension_age_sex_class_type
		
		tempfile pension_age_sex_class
		tempfile pension_age_sex_type
		tempfile pension_age_class_type
		tempfile pension_sex_class_type
		
		tempfile pension_age_sex
		tempfile pension_sex_class
		tempfile pension_sex_type
		tempfile pension_age_class
		tempfile pension_age_type
		tempfile pension_class_type
		
		tempfile pension_sex
		tempfile pension_age
		tempfile pension_class
		tempfile pension_type
		tempfile pension_wage
		tempfile pension_total

		// Wage cross-sections (2-way)
		tempfile pension_wage_sex
		tempfile pension_wage_age
		tempfile pension_wage_class
		tempfile pension_wage_type

		// Wage cross-sections (3-way)
		tempfile pension_wage_sex_age
		tempfile pension_wage_sex_class
		tempfile pension_wage_sex_type
		tempfile pension_wage_age_class
		tempfile pension_wage_age_type
		tempfile pension_wage_class_type

		// Wage cross-sections (4-way)
		tempfile pension_wage_sex_age_class
		tempfile pension_wage_sex_age_type
		tempfile pension_wage_sex_class_type
		tempfile pension_wage_age_class_type

		// Wage cross-sections (5-way: all dimensions)
		tempfile pension_wage_sex_age_class_type
		

		

		
		// Generate status totals
		capture drop  newly_retired
		capture drop  retired
		capture drop  disabled
		capture drop  widowed
		capture drop  deceased
		capture drop  has_min_pension
		capture drop  has_lumpsum
		capture drop government_pension_subsidy
		generate newly_retired   			 = weight * (status == 2) * (startyear == `yr')
		generate retired  	 	 			 = weight * (status == 2)
		generate disabled    	 			 = weight * (status == 3)
		generate widowed     	 			 = weight * (status == 4)
		generate deceased    	 			 = weight * (died_flag)	
		generate has_min_pension 			 = weight * minimum_pension    * (status !=99)
		generate has_lumpsum	 			 = weight * gets_lumpsum       * (status !=99)
		generate government_pension_subsidy	 = weight * gov_minpen_subsidy * (status !=99)
		


		// In-year reporting by decile and gender:
		local sumvars 		  = "newly_retired retired disabled widowed deceased has_min_pension has_lumpsum government_pension_subsidy"
		local meanvars 		  = "avg_pension=pension_benefit replacement_rate income_adequacy db_years_early db_years_late  average_wage reference_wage"
		local meanvars_totals = "avg_pension=pension_benefit replacement_rate income_adequacy db_years_early db_years_late  average_wage reference_wage"


	
		
		**********
		// In-year reporting totals by gender, age, class and pension type:
		preserve
			// Collapse by gender, age, class, and type
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender age_grp pension_class pension_type)
			generate year = `yr'
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age_sex_class_type', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by gender, age, and class:
		preserve
			// Collapse by gender, age, class, and type
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender age_grp pension_class)
			generate year = `yr'
			generate pension_type = 999 	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age_sex_class', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by gender, age, and pension type:
		preserve
			// Collapse by gender, age, class, and type
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender age_grp pension_type)
			generate year = `yr'
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age_sex_type', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by age_grp, class and pension type:
		preserve
			// Collapse by age, class, and type
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(age_grp pension_class pension_type)
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age_class_type', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by gender, class and pension type:
		preserve
			// Collapse by gender, age, class, and type
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender pension_class pension_type)
			generate year = `yr'
			generate age_grp = 999 			// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_sex_class_type', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by gender, age:
		preserve
			// Collapse by gender, age
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender age_grp)
			generate year = `yr'
			generate pension_type = 999 	// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age_sex', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by gender and class:
		preserve
			// Collapse by gender and class
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender pension_class)
			generate year = `yr'
			generate age_grp = 999 			// Totals placeholder
			generate pension_type = 999 	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_sex_class', emptyok replace
		restore
		

			**********
		// In-year reporting totals by gender and pension type:
		preserve
			// Collapse by gender and type
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender pension_type)
			generate year = `yr'
			generate age_grp = 999 			// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_sex_type', emptyok replace
		restore
		
		
		
		**********
		// In-year reporting totals by age and class:
		preserve
			// Collapse by age and class
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(age_grp pension_class)
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate pension_type = 999 	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age_class', emptyok replace
		restore
		
		
		
		**********
		// In-year reporting totals by age and pension type:
		preserve
			// Collapse by age and type
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(age_grp pension_type)
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age_type', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by class and pension type:
		preserve
			// Collapse by class and type
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(pension_class pension_type)
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate age_grp = 999 			// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_class_type', emptyok replace
		restore
		
		
		
		**********
		// In-year reporting totals by gender:
		preserve
			// Collapse by gender
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(gender)
			generate year = `yr'
			generate age_grp = 999 			// Totals placeholder
			generate pension_type = 999 	// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_sex', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by age:
		preserve
			// Collapse by age
			*generate age_grp = floor(age / 5) * 5  // 5-year grouping
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(age_grp)
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate pension_type = 999 	// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_age', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by class:
		preserve
			// Collapse by class
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(pension_class)
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate age_grp = 999 			// Totals placeholder
			generate pension_type = 999 	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_class', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals by pension type:
		preserve
			// Collapse by type
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(pension_type)
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate age_grp = 999 			// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_type', emptyok replace
		restore
		
		
		**********
		// In-year reporting totals:
		preserve
			// Collapse
			collapse (sum) `sumvars' (mean) `meanvars_totals'  if status !=99
			generate year = `yr'
			generate gender = 99 			// Totals placeholder
			generate age_grp = 999 			// Totals placeholder
			generate pension_type = 999 	// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			generate wage_decile_ret = 99	// Totals placeholder
			// Save totals
			save `pension_total', emptyok replace
		restore


		**********
		// In-year reporting by wage decile (1-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			generate age_grp = 999			// Totals placeholder
			generate pension_type = 999		// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			save `pension_wage', emptyok replace
		restore


		**********
		// In-year reporting by wage and sex (2-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender)
			generate year = `yr'
			generate age_grp = 999			// Totals placeholder
			generate pension_type = 999		// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			save `pension_wage_sex', emptyok replace
		restore


		**********
		// In-year reporting by wage and age (2-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret age_grp)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			generate pension_type = 999		// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			save `pension_wage_age', emptyok replace
		restore


		**********
		// In-year reporting by wage and class (2-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret pension_class)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			generate age_grp = 999			// Totals placeholder
			generate pension_type = 999		// Totals placeholder
			save `pension_wage_class', emptyok replace
		restore


		**********
		// In-year reporting by wage and pension type (2-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret pension_type)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			generate age_grp = 999			// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			save `pension_wage_type', emptyok replace
		restore


		**********
		// In-year reporting by wage, sex and age (3-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender age_grp)
			generate year = `yr'
			generate pension_type = 999		// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			save `pension_wage_sex_age', emptyok replace
		restore


		**********
		// In-year reporting by wage, sex and class (3-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender pension_class)
			generate year = `yr'
			generate age_grp = 999			// Totals placeholder
			generate pension_type = 999		// Totals placeholder
			save `pension_wage_sex_class', emptyok replace
		restore


		**********
		// In-year reporting by wage, sex and pension type (3-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender pension_type)
			generate year = `yr'
			generate age_grp = 999			// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			save `pension_wage_sex_type', emptyok replace
		restore


		**********
		// In-year reporting by wage, age and class (3-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret age_grp pension_class)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			generate pension_type = 999		// Totals placeholder
			save `pension_wage_age_class', emptyok replace
		restore


		**********
		// In-year reporting by wage, age and pension type (3-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret age_grp pension_type)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			generate pension_class = 999	// Totals placeholder
			save `pension_wage_age_type', emptyok replace
		restore


		**********
		// In-year reporting by wage, class and pension type (3-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret pension_class pension_type)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			generate age_grp = 999			// Totals placeholder
			save `pension_wage_class_type', emptyok replace
		restore


		**********
		// In-year reporting by wage, sex, age and class (4-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender age_grp pension_class)
			generate year = `yr'
			generate pension_type = 999		// Totals placeholder
			save `pension_wage_sex_age_class', emptyok replace
		restore


		**********
		// In-year reporting by wage, sex, age and pension type (4-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender age_grp pension_type)
			generate year = `yr'
			generate pension_class = 999	// Totals placeholder
			save `pension_wage_sex_age_type', emptyok replace
		restore


		**********
		// In-year reporting by wage, sex, class and pension type (4-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender pension_class pension_type)
			generate year = `yr'
			generate age_grp = 999			// Totals placeholder
			save `pension_wage_sex_class_type', emptyok replace
		restore


		**********
		// In-year reporting by wage, age, class and pension type (4-way):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret age_grp pension_class pension_type)
			generate year = `yr'
			generate gender = 99			// Totals placeholder
			save `pension_wage_age_class_type', emptyok replace
		restore


		**********
		// In-year reporting by wage, sex, age, class and pension type (5-way — all dimensions):
		preserve
			drop if missing(wage_decile_ret)	// Exclude pensioners with no decile (avoids duplicate 99-totals)
			collapse (sum) `sumvars' (mean) `meanvars' if status !=99, by(wage_decile_ret gender age_grp pension_class pension_type)
			generate year = `yr'
			save `pension_wage_sex_age_class_type', emptyok replace
		restore


		// Accumulate in-year reporting into reporting database - TOTALS
		preserve
			use `inyear_pension_reporting_tot', clear
			append using `pension_total'
			save `inyear_pension_reporting_tot', replace
		restore
		
		
		// Accumulate in-year reporting into reporting database - BREAKDOWNS
		preserve
			use `inyear_pension_reporting', clear
			append using `pension_age_sex_class_type'
			append using `pension_age_sex_class'
			append using `pension_age_sex_type'
			append using `pension_age_class_type'
			append using `pension_sex_class_type'
			append using `pension_age_sex'
			append using `pension_sex_class'
			append using `pension_sex_type'
			append using `pension_age_class'
			append using `pension_age_type'
			append using `pension_class_type'
			append using `pension_sex'
			append using `pension_age'
			append using `pension_class'
			append using `pension_type'
			// Wage cross-sections
			append using `pension_wage_sex_age_class_type'
			append using `pension_wage_sex_age_class'
			append using `pension_wage_sex_age_type'
			append using `pension_wage_sex_class_type'
			append using `pension_wage_age_class_type'
			append using `pension_wage_sex_age'
			append using `pension_wage_sex_class'
			append using `pension_wage_sex_type'
			append using `pension_wage_age_class'
			append using `pension_wage_age_type'
			append using `pension_wage_class_type'
			append using `pension_wage_sex'
			append using `pension_wage_age'
			append using `pension_wage_class'
			append using `pension_wage_type'
			append using `pension_wage'
			save `inyear_pension_reporting', replace
		restore
		
		


		// Drop reporting variables
		capture drop retired
		capture drop disabled
		capture drop widowed
		capture drop deceased	

		
		
		************************************************************************
		************************************************************************
		// Stage 5: Update values
		replace age     = age  + 1 if status != 99
		replace age_grp = floor(age / 5) * 5
		replace year    = year + 1
		
		// Update status for those who recently died
		replace status = 99 		if died_flag == 1 // Status 99 means dead

		
		
		} // end forvalues yr


********************************************************************************
//	Final reporting on the pensioner database
	// Clean up tempvars before saving
	capture drop __00*
	
	// Export the data
	*cd "`outdir'"
	export delimited using "`outdir'\1_PROSTv2-`simname'-Pensioners-`startyear'-`endyear'.csv", replace	
	
	save "`outdir'\1_PROSTv2-`simname'-Pensioners-`startyear'-`endyear'.dta", replace	
	
	





********************************************************************************



		
********************************************************************************
//	Export in-year affiliate reporting	- TOTALS
	use `inyear_affiliate_reporting_tot', clear
	
	// Define labels to identify placeholders
	label define agetotal_LAB 999 "Total", add
	label define decile_LAB 99 	"Total", add
	label define gender_LAB ///
		 1 "Male"	/// 
		 2 "Female"	///
		99 "Total"	, add
	label define dens_LAB ///
		 1 "Active"	/// 
		 0 "Inactive"	///
		99 "Total"	, add
	
	// Add labels
	label values age			agetotal_LAB
	label values wage_decile 	decile_LAB
	label values gender 		gender_LAB
	label values dens 			dens_LAB

	
	// Order the data
	order year age gender wage_decile dens
	
	// Export dataset
	*cd "`outdir'"
	export delimited using "`outdir'\1_PROSTv2-`simname'-Inyear-Affiliate-Reporting-Totals.csv", replace
	
	
********************************************************************************
//	Export in-year affiliate reporting	- BREAKDOWNS
	use `inyear_affiliate_reporting', clear
	
	// Define labels to identify placeholders
	label define agetotal_LAB 999 "Total", add
	label define decile_LAB 99 	"Total"
	label define gender_LAB ///
		 1 "Male"	/// 
		 2 "Female"	///
		99 "Total"	, add
	capture label define dens_LAB ///
		 1 "Active"	/// 
		 0 "Inactive"	///
		99 "Total"	, add
	
	// Add labels
	label values age			agetotal_LAB
	label values wage_decile 	decile_LAB
	label values gender 		gender_LAB
	label values dens 			dens_LAB

	
	// Order the data
	order year age gender wage_decile dens
	
	// Export dataset
	*cd "`outdir'"
	export delimited using "`outdir'\1_PROSTv2-`simname'-Inyear-Affiliate-Reporting-Breakdowns.csv", replace
	

********************************************************************************
//	Export in-year pensioner reporting	

	// Open the dataset
	use `inyear_pension_reporting_tot', clear
	
	// Checks for common issues:
	assert !missing(year)          // Ensure every row has a year (missing year = broken accumulation)
	assert !missing(gender)        // Placeholder 99 should be present, but never truly missing
	assert pension_type != .       // All rows should have a pension type or the 999 placeholder
		
	// Define labels to identify placeholders
	label define age_LAB			999	"Total", add
	label define pension_type_LAB	999	"Total", add
	label define pension_class_LAB	999	"Total", add
	label define gender_LAB ///
		 1 "Male"	///
		 2 "Female"	///
		99 "Total"	, add
	label define wage_decile_ret_LAB ///
		99 "Total"	, add

	// Add labels
	label values gender 		gender_LAB
	label values pension_type 	pension_type_LAB
	label values pension_class	pension_class_LAB
	label values age_grp		age_LAB
	label values wage_decile_ret	wage_decile_ret_LAB

	// Order the data
	order year gender age_grp wage_decile_ret
	
	// Export dataset
	*cd "`outdir'"
	export delimited using "`outdir'\1_PROSTv2-`simname'-Inyear-Pensioner-Reporting-Totals.csv", replace
	
	
	
	
********************************************************************************
//	Export in-year pensioner reporting

	// Open the dataset
	use `inyear_pension_reporting', clear

	// Non-wage cross-sections have no wage_decile_ret — fill with Total placeholder
	capture replace wage_decile_ret = 99 if missing(wage_decile_ret)

	// Checks for common issues:
	assert !missing(year)          // Ensure every row has a year (missing year = broken accumulation)
	assert !missing(gender)        // Placeholder 99 should be present, but never truly missing
	assert pension_type != .       // All rows should have a pension type or the 999 placeholder

	// Define labels to identify placeholders
	label define age_LAB			999	"Total", add
	label define pension_type_LAB	999	"Total", add
	label define pension_class_LAB	999	"Total", add
	label define gender_LAB ///
		 1 "Male"	///
		 2 "Female"	///
		99 "Total"	, add
	label define wage_decile_ret_LAB ///
		99 "Total"	, add

	// Add labels
	label values gender 		gender_LAB
	label values pension_type 	pension_type_LAB
	label values pension_class	pension_class_LAB
	label values age_grp		age_LAB
	label values wage_decile_ret	wage_decile_ret_LAB

	// Order the data
	order year gender age_grp wage_decile_ret

	// Export dataset
	*cd "`outdir'"
	export delimited using "`outdir'\1_PROSTv2-`simname'-Inyear-Pensioner-Reporting-Breakdowns.csv", replace
	
	
********************************************************************************

*} // end quietly


// 	Timer
	timer off 1
	timer list 1
	


