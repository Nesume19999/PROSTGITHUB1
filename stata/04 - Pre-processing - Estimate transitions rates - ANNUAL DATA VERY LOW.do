/*******************************************************************************
Title: 			Estimate transitions rates from longitudinal data - ANNUAL DATA VERY LOW
Author: 		Duncan MacDonald
Date created: 	September 30th, 2026
Description:	For building PROST v2 pension model (Revised)

Note: Estimates two monthly hazard rates - job_exit (transition_out) and job_entry
	  (transition_in) - rather than predicting `dens' (months worked, 0-12) directly.
	  The build script ("1 - PROSTv2 - Build projection database - ANNUAL DATA VERY
	  LOW.do", Stage 5) simulates a 12-step employment-status Markov chain from these
	  two hazards to produce each year's `dens', which reproduces within-year
	  persistence (an employed person tends to stay employed) without a full monthly
	  panel expansion.

Transition out model:
	glm transition_out_ind c.log_spell_length i.wage_decile_ref c.density_decile c.log_spell_length#c.density_decile c.age##c.age i.gender c.los_gap i.retirement_age i.no_hope if dens >= 10, family(binomial) link(cloglog) cluster(id)

Transition in model:
	glm transition_in_ind c.log_spell_length i.wage_decile_ref c.density_decile c.age##c.age i.gender c.log_cod c.los_gap i.retirement_age i.no_hope if dens <= 2, family(binomial) link(cloglog) cluster(id)

Note: `density_decile' is a person's career-long contribution density decile - their
	  permanent propensity to contribute. It enters as a CONTINUOUS term
	  (c.density_decile), not categorical, because the outcome-filtered estimation
	  samples (dens<=2 for entry, dens>=11 for exit) have near-zero support in some
	  deciles, which causes quasi-separation under a categorical specification.

Note: `c.log_spell_length#c.density_decile' lets the exit hazard's duration
	  dependence vary by reliability type - long-tenured people in high density
	  deciles become disproportionately stickier the longer they stay, which a
	  decile-blind duration term cannot represent.

Note: `log_spell_length' = log(spell_length+1), not a raw linear `spell_length'
	  term, so very long tenures (common over a multi-decade projection horizon but
	  rare in the estimation data) aren't extrapolated on an unbounded linear scale.
	  The +1 (log1p) avoids log(0)=missing for spell_length==0, the most common value
	  in both estimation samples.

Note: `transition_out_ind' is built as entry_pred * (1-cd)/cd rather than
	  entry_pred / (cd/(1-cd)), so contribution_density==1 (zero exit hazard)
	  evaluates to exactly 0 instead of a missing value from dividing by zero.

Note: wage_decile_ref enters the exit model as a level control only, with no
	  duration-slope interaction - density_decile is the sole driver of
	  duration-dependence heterogeneity (confirmed by holdout likelihood-ratio tests).

Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools


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
	local long_data  		 = "2 Input from client - longitudinal microdata about affiliates.dta"


//	Simulation parameters
	local years_avg   = 10  	// Number of years of back data to average over
	local minimum_age = 15		// Minimum age to consider (some young ages don't have a lot of data)
	local samplesize  = 20		// Sample size of the estimation data (100 is a full sample, 1 is a 1% sample) - [Only when testing]


//	Output model names
	local job_entry_model 	= "job_entry_model_`country'_`years_avg'_ANNUAL_DATA_VERY_LOW"	// transition_in hazard (monthly re-entry probability)
	local job_exit_model 	= "job_exit_model_`country'_`years_avg'_ANNUAL_DATA_VERY_LOW"		// transition_out hazard (monthly exit probability)



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
	sort id year


//	Identify the start of a new spell (status change or new person)
//	Uses only LAST year's (already-realized) dens/loa - using this row's own
//	not-yet-realized dens would be tautological.
	generate byte new_spell = 1 if _n == 1 | id != id[_n-1]
	replace  new_spell = (dens[_n-1] < 12 & dens[_n-1] > 0 | dens[_n-1] == loa[_n-1]) if id == id[_n-1]


//	Identify the number of new spells that are obsered
//	Create a unique ID for every single spell in the dataset
	generate spell_id = sum(new_spell)

//	Calculate the length of every spell, AS OF THE START of the current year (lagged,
//	excluding the current row's own `dens') - must match what the build script feeds
//	in as a pre-determined covariate at simulation time.
	bysort id spell_id: generate spell_length = sum(dens) - dens		// Lagged time-in-spell (as of start of year)


//  log1p of spell duration - avoids log(0)=missing for spell_length==0, the most
//	common value in both estimation samples.
	generate log_spell_length = log(spell_length + 1)

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
//	Impute wages for those who are not working
//	Note: The heckman selection model does not work well here, so we keep a regular regression
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
//	Compute transition rates
// 	Note: As we cannot estimate transition rates directly then we need to compute
//	aggregate transition rates from contribution density (steady-state identity)
//	Steady state employment rate:  los / loa = λ_in / (λ_in + λ_out)

//	First, get the average transition_out rate for those in work by wage decile, gender and age
//	We do this by looking at the number of workers with less than 12 contributions in the current year
//	We compare this with the number of active months were worked within each cohort
	generate did_transition = (dens > 0 & dens < 12)
	bysort wage_decile_ref gender age: egen transitions = total(did_transition) // Number of transitions E -> U
	bysort wage_decile_ref gender age: egen months_worked = total(dens) 		// Number of months worked
	generate transition_out = transitions / months_worked

//	Then we compute transition_in rates based on the steady state employment rate equation:
	generate adjustment = (contribution_density / (1 - contribution_density))
	generate transition_in_ind = transition_out * (contribution_density / (1 - contribution_density))
	replace  transition_in_ind = min(transition_in_ind, 1)	// Put a cap on transition_in_ind

//	Get the average contribution density by wage decile, age, and gender
	bysort wage_decile_ref gender age: egen transition_in = mean(transition_in_ind)


********************************************************************************
//	Estimating spell-dependent transition rates
//	GLM with a cloglog link, since the target is a fractional [0,1] rate, not a
//	binary 0/1 outcome. See the file header note for why density_decile enters as
//	a continuous (not categorical) term.

//	Focus on those with low in-year density as an approximation of those currently out of work
	glm transition_in_ind c.log_spell_length i.wage_decile_ref c.density_decile c.age##c.age i.gender c.log_cod c.los_gap i.retirement_age i.no_hope if dens <= 2, family(binomial) link(cloglog) cluster(id)
	predict entry_annual_data_very_low
	cd "`transdir'"
	estimates save "`job_entry_model'", replace

//	Update our transition out_rates
// 	Focus on those with high in-year density as an approximation of those currently in work.
//	Built as entry_pred * (1-cd)/cd (not entry_pred / (cd/(1-cd))) so that
//	contribution_density==1 evaluates to exactly 0 (zero exit hazard) instead of a
//	missing value from dividing by zero.
	generate transition_out_ind = entry_annual_data_very_low * (1 - contribution_density) / contribution_density
	glm transition_out_ind c.log_spell_length i.wage_decile_ref c.density_decile c.log_spell_length#c.density_decile c.age##c.age i.gender c.los_gap i.retirement_age i.no_hope if dens >= 10, family(binomial) link(cloglog) cluster(id)
	predict exit_annual_data_very_low
	cd "`transdir'"
	estimates save "`job_exit_model'", replace


********************************************************************************
