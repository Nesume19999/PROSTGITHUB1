/******************************************************************************* 
Title: 			Estimate transitions rates from longitudinal data - ANNUAL DATA
Author: 		Duncan MacDonald 
Date created: 	March 18th, 2026
Description:	For building PROST v2 pension model (Revised)


Transition out model: 
	cloglog transition_out c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.los_gap if den == 1, cluster(id) 
	
Transition in model: 
	cloglog transition_in c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.log_cod c.los_gap if dens == 0, cluster(id)
	
	
Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools
ssc install betabin
ssc install zibbin


Note: Here we define deciles as the last known decile of the person as the decile 
	  they had for their entire career. 
	  That is, their most recent decile is their "true" decile.
	  
	  Annual data is annual aggregate contributions per person for each year 
	  
			
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause on
	set trace off
	
	set seed 1

//	Country iso3 code
	local country  = "MEX"

//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local indir		 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local homedir 		= "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local transdir		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\transitions"

//	Name of input data	
	local annual_data 		 = "annual_`country'"
	local low_data 			 = "lowdata_`country'"
	local very_low_data 	 = "verylowdata_`country'"
	local extremely_low_data = "extremelylowdata_`country'"
	local long_data  		 = "2 Input from client - longitudinal microdata about affiliates.dta"


//	Simulation parameters
	local years_avg   = 10  	// Number of years of back data that are averaged to generate (we use 1 right now to )
	local minimum_age = 15		// Minimum age to consider (some young ages don't have a lot of data)
	local samplesize  = 20		// Sample size of the projection database (100 is a full sample, 1 is a 1% sample) - [Only when testing]

	
//	Output model names
	local full_dens_model 		= "full_dens_model_`country'_`years_avg'_ANNUAL_DATA"
	local partial_dens_model 	= "partial_dens_model_`country'_`years_avg'_ANNUAL_DATA"
	local tobit_model 			= "tobit_model_`country'_`years_avg'_ANNUAL_DATA"
	local betabin_model			= "betabin_model_`country'_`years_avg'_ANNUAL_DATA"
	local zibbin_model			= "zibbin_model_`country'_`years_avg'_ANNUAL_DATA"


	
//	Parameters of the current pension system
//	We need these as we compute transition rates as a function of time to retirement
	local retage_earliest = 60				// Easliest possible retirement age - (Cesantía en Edad Avanzada)
	local retage_male = 65 					// Male retirement age
	local retage_female = 65				// Female retirement age
	local retcont_min = (750 / 52) * 12		// Minimum contribution threshold (in months)

	
********************************************************************************
// 	Open the longitudinal microdata about affiliates
	cd "`indir'"
	use "`annual_data'", clear
	
	
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

// 	There is too much data for the model to run in a reasonable time during testing
// 	We need to sample people, but they have multiple observations in the base dataset
//	[TODO: Consider a stratified sample]
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

********************************************************************************
//	Compute spells of unemployment and job tenure

//	Set up time series data
	*generate date = ym(year, month)
	sort id year
	

//	Identify the start of a new spell (status change or new person)
	*generate byte new_spell = (dens != dens[_n-1] | id != id[_n-1]) 
	*generate byte new_spell = ((dens != dens[_n-1] | id != id[_n-1])  & month != 1)
	generate byte new_spell = (dens < 12 & dens > 0 | dens == loa)

	
//	Identify the number of new spells that are obsered
	*bysort id (year) : generate spells = sum(new_spell)
	

//	Create a unique ID for every single spell in the dataset
	generate spell_id = sum(new_spell)

//	Calculate the length of every spell, AS OF THE START of the current year (i.e. lagged,
//	excluding the current row's own `dens') - not the year-end/inclusive total.
//	Note: `sum(dens)' alone is a RUNNING, INCLUSIVE sum - for the first row of any spell that
//	makes spell_length exactly equal to that same row's own dens, so spell_length == 0 would
//	occur if and only if dens == 0 for that identical observation (a tautology, not a genuine
//	predictive relationship). Since the simulation uses spell_length as a pre-determined,
//	lagged covariate to predict THIS year's not-yet-realized dens (e.g. every new affiliate
//	starts at spell_length = 0, before any outcome is drawn for them), the model must be
//	trained on the same lagged definition - otherwise it learns "spell_length == 0" as an
//	almost hard-wired signal for dens == 0 purely from how the training variable was
//	constructed, and applies that same near-certainty to new entrants at simulation time, who
//	have not actually had an outcome determined yet. Subtracting the current row's own dens
//	converts the inclusive running sum into the correct lagged (start-of-year) value.
	*bysort id spell_id: generate total_spell_length = _N		// Total time in the spell
	*bysort id spell_id: generate spell_length = _n  			// time-in-spell to date
	bysort id spell_id: generate spell_length = sum(dens) - dens		// Lagged time-in-spell (as of start of year)

	
//	Impute approximate spell length
	*generate spell_length_approx = los
	*replace  spell_length_approx = loa - los if dens == 0
	
//	Replace spell_length with approximate spell length for when spell is censored
	*replace spell_length = spell_length_approx if spells == 0
	
	
//  Log of spell duration
	generate log_spell_length = log(spell_length)

//	Compute contribution density
	generate contribution_density = los / loa
	
//	Compute log of contribution density
	generate log_cod = log(max(contribution_density, 0.001))
	
// 	Compute the density decile for each person
//	This represents a person's permanent propensity to contribute
	generate cod_rand = contribution_density + runiform()/10000	// Add a bit of noise to split ties
	xtile density_decile = cod_rand, nq(10)
	
		


   

	
	
********************************************************************************
// Compute some pension-rule-specific indicators (for incusion into the model)	
	
// 	Months until reaching eligible retirement age
	generate age_gap = 0
	replace  age_gap = max(`retage_male'   - age, 0) * 12 if gender == 1 // Male
	replace  age_gap = max(`retage_female' - age, 0) * 12 if gender == 2 // Female
	
// 	Months of contributions requred to be eligible for an old-age pension
	generate los_gap = max(`retcont_min' - los, 0)
	
// 	As both age_gap and los_gap must be filled, we take the max for the model
	generate pension_gap = max(age_gap, los_gap)
	
//	Indicator: person has no hope of being eligible for a pension
	generate no_hope = (los_gap  >= age_gap)
	
//	Determine the earliest age at which people can retirement
	generate retirement_age = (age >= `retage_earliest')
	
	
********************************************************************************
//	Exclusion criteria: continuous hazard proxy 
//	How fast do people lose active status per period of affiliation?
	*generate hazard_proxy = (1 - contribution_density) / loa 

//	Impute wages for those who are not working
//	Note: The heckman selection model does not work well here, so we keep a regular regression
	*generate working = (!missing(wage))
	*heckman wage c.contribution_density i.gender c.age##c.age, select(working = hazard_proxy c.contribution_density i.gender c.age##c.age) cluster(id)
	reg wage c.contribution_density i.gender c.age##c.age 
	predict wage_pred
	generate imputed_wage = wage
	sort id year										// Sort the data
	by id: carryforward imputed_wage, replace			// Carry the latest non-missing data forward
	replace  imputed_wage = wage_pred if missing(imputed_wage)
	
	
//	Build a wage growth index from your own data (mean wage each year)
	bysort year: egen mean_wage_yr = mean(imputed_wage)				// Average wage in each year
	generate wage_relative_mean = imputed_wage / mean_wage_yr   	// Compute the wage relative to the mean 
	sort id year													// Sort the data
	by id: carryforward wage_relative_mean, replace					// Carry the latest non-missing data forward
	
//  Deciles (using faster gtools) [Compute using relative wages, so we don't need to index]
	*gquantiles wage_decile_ref_last = wage_relative_mean if year == `latest_year' & month==12 , xtile nquantiles(10) by(year) 
	gquantiles wage_decile_ref_last = wage_relative_mean if year == `latest_year'  , xtile nquantiles(10) by(year) 

	bysort id: egen wage_decile_ref = max(wage_decile_ref_last)
	drop wage_decile_ref_last
	
	
//	Compute a reference wage decile (for those people who are not working currently)
	generate wage_decile = wage_decile_ref
	
//	Fill in observed wage_decile with 0 when not working formally
	replace  wage_decile = 0 if dens ==0 // Unemployed or working informally
	
	
	
// 	Pre-processing (drop data and compute wage deciles)
	// Keep only the most recent years
	// Note: We do this only after getting a person's wage_decile_ref
	keep if year > `latest_year'  - `years_avg'
	keep if age >= `minimum_age'


********************************************************************************
// //	Build a wage growth index from your own data (mean wage each year)
// 	bysort year: egen mean_wage_yr = mean(wage)			// Average wage in each year
// 	generate wage_relative_mean = wage / mean_wage_yr   // Compute the wage relative to the mean 
// 	sort id date										// Sort the data
// 	by id: carryforward wage_relative_mean, replace		// Carry the latest non-missing data forward
// 	// TODO: Fix this. Here we have only limited information about people with no wage data (and so no issing data). This is not an issue for the longitudial data
//	
//	
// //  Deciles (using faster gtools) [Compute using relative wages, so we don't need to index]
// 	gquantiles wage_decile_ref_last = wage_relative_mean if year == `latest_year' & month==12 , xtile nquantiles(10) by(year) 
// 	bysort id: egen wage_decile_ref = max(wage_decile_ref_last)
// 	drop wage_decile_ref_last
//	
//	
// //	Compute a reference wage decile (for those people who are not working currently)
// 	generate wage_decile = wage_decile_ref
//	
// //	Fill in observed wage_decile with 0 when not working formally
// 	replace  wage_decile = 0 if dens ==0 // Unemployed or working informally
//	
//	
//	
// // 	Pre-processing (drop data and compute wage deciles)
// 	// Keep only the most recent years
// 	// Note: We do this only after getting a person's wage_decile_ref
// 	keep if year > `latest_year'  - `years_avg'
// 	keep if age >= `minimum_age'


********************************************************************************
// 	Compute transition rates
// 	Note: For the annualized data we want to determine two things:
//		First: How likely is it that you worked all year
//		Second: If you didn't work all year, how many months did you work

//	Boolean: Did you work the full 12 months
	generate full_year = (dens == 12)
	generate months = 12	// Number of months in a 
	generate log_loa = log(loa + 1)

//	Superseded by the pooled tobit model below - kept for reference/comparison.
//	Model 1: probability of working the full year
	*cloglog full_year c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.los_gap i.retirement_age i.no_hope, cluster(id)
	*cloglog full_year c.spell_length##c.spell_length##i.wage_decile_ref c.age##c.age##c.age i.gender i.density_decile c.los_gap i.retirement_age i.no_hope, cluster(id)
	*cd "`transdir'"
	*estimates save "`full_dens_model'", replace


//	Model 2: conditional distribution of months, given not a full year
	*nbreg dens c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.los_gap i.retirement_age i.no_hope if full_year == 0, vce(cluster id)
	*nbreg dens c.spell_length##c.spell_length##i.wage_decile_ref c.age##c.age##c.age i.gender i.density_decile c.los_gap i.retirement_age i.no_hop if full_year == 0, cluster(id)
	*ologit dens c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.los_gap i.retirement_age i.no_hope if full_year == 0, vce(cluster id)
	*cd "`transdir'"
	*estimates save "`partial_dens_model'", replace
	
	
//	Model: pooled tobit model of months worked (dens), censored at [0,12]
	*tobit dens c.spell_length##c.spell_length##i.wage_decile_ref c.age##c.age##c.age i.gender i.density_decile c.los_gap i.retirement_age i.no_hope, ll(0) ul(12) vce(cluster id)
	*cd "`transdir'"
	*estimates save "`tobit_model'", replace
	
	
	
//	Model Zero-inflated beta-binomial regression
	zibbin dens c.spell_length##c.spell_length##i.wage_decile_ref c.age##c.age i.gender i.density_decile c.los_gap c.log_loa i.retirement_age i.no_hope, ///
    inflate(i.density_decile c.log_loa c.spell_length i.gender c.los_gap i.no_hope) ///
    n(months) link(logit) ilink(logit) vce(cluster id) zib
	cd "`transdir'"
	estimates save "`zibbin_model'", replace
	
	
//	Model beta-binomial regression

	*bysort id (year): generate dens_last = dens[_n-1]
	betabin dens c.spell_length##c.spell_length##i.wage_decile_ref c.log_loa i.density_decile c.age##c.age i.gender c.los_gap i.retirement_age i.no_hope, n(months) vce(cluster id)


	gen used_sample = e(sample)
	
	cd "`transdir'"
	estimates save "`betabin_model'", replace
	
	
	predict predict_n, n
	predict predict_xb, xb
	predict predict_pr, pr


	*gen resid = dens - (predict_pr*12)

	

	
	
********************************************************************************
	
	
	

