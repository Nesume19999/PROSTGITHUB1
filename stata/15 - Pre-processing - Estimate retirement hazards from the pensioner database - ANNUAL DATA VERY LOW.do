/*******************************************************************************
Title: 			Estimate retirement hazards from the pensioner database - ANNUAL DATA VERY LOW
Author: 		Duncan MacDonald
Date created: 	October 21st, 2026
Description:	For building PROST v2 pension model (Revised)

Note: Estimates the probability of retiring at each age, by gender, from the
	  PENSIONER DATABASE ONLY (no information on the affiliates who have not retired).
	  It is used by the projection when  retirement_rule = 3.

	  The pensioner file gives, for each old-age pension, the age of the pensioner and the
	  year in which the pension started, so the age at retirement is known. For gender g:

		retirees(a)  = number of old-age pensions started at age a   (last years_avg years)
		at_risk(a)   = number of old-age pensions started at age a or later (all ages in the file)
		hazard(a)    = retirees(a) / at_risk(a)

	  hazard(a) is the probability of retiring at age a for a person who retires at age a
	  or later. It is estimated for the ages that are observed in the retirement database
	  ("07 - ... - AGE ONLY.do"): the ages up to which the retirement model has information.
	  The oldest age is the age of the normal retirement; the projection uses the hazard of
	  that age for all the older ages (as the age-only model does).

Note: Differences from "08 - Pre-processing - Estimate retirement rates - ANNUAL DATA VERY LOW
	  - AGE ONLY.do", which also uses the affiliates who have not retired:
	  - There is no pool of affiliates who never retire: everybody who is at risk at age a retires
	    at age a or later. The hazards are therefore larger than the hazards estimated on the
	    affiliates, and nearly everybody has retired by the early seventies, as in the pensioner file.
	  - The number of retirees in the projection is the number of eligible affiliates (the model
	    population) times these hazards. Check it against the number of new pensions in the pension
	    file, or use the retirement anchor of the projection.
	  - The pensions are those of people who survived to retire: the hazards are conditional on
	    surviving, and the projection applies mortality to the affiliates separately.
	  - It is a cross-section of the retirements of the last years, so the hazards are those of a
	    synthetic cohort (cohorts retiring at different ages are not followed).

Input:
	pensioners_MEX.dta									[Input folder]
	retirement_database_MEX_AGE_ONLY.dta				[Input folder, only for the range of ages]

Output:
	retirement_eligible_rates_MEX_ANNUAL_DATA_VERY_LOW_PENSIONER_DB.csv		[retirement folder]
		(gender, age, retirees, at_risk, retirement_prob_eligible)

*******************************************************************************/

//	INITIALIZATION
	clear all
	pause off
	set trace off

//	Country iso3 code
	local country  = "MEX"

//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local indir		 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local retiredir		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\retirement"

//	Name of input data
	local pensioners_data	= "pensioners_`country'.dta"
	local retirement_db		= "retirement_database_`country'_AGE_ONLY"

//	Simulation parameters
	local data_year   = 2020	// Year of the pension file (age = age in this year)
	local years_avg   = 5		// Number of years of pensions to use (the pensions started in the last years_avg years)
	local old_age     = 1		// Value of pension_type for the old-age pensions

//	Output
	local hazard_csv  = "retirement_eligible_rates_`country'_ANNUAL_DATA_VERY_LOW_PENSIONER_DB"


********************************************************************************
//	Ages observed in the retirement database
	cd "`indir'"
	use "`retirement_db'", clear
	summarize age
	local min_age = r(min)
	local max_age = r(max)
	display as text "Ages of the retirement database: `min_age' to `max_age'"


********************************************************************************
//	Pensioner database: age at retirement of the old-age pensions started in the last years
	use "`pensioners_data'", clear
	keep if pension_type == `old_age'
	keep if startyear > `data_year' - `years_avg' & startyear <= `data_year'
	generate age_ret = age - (`data_year' - startyear)
	drop if age_ret < `min_age'			// Pensions at younger ages are not part of the retirement database

	display as text "Old-age pensions started in " `data_year' - `years_avg' + 1 " to `data_year': " _N

//	Number of retirees by gender and age at retirement (all ages)
	contract gender age_ret, freq(retirees)

//	At risk at age a: those who retire at age a or later
	gsort gender -age_ret
	by gender: generate double at_risk = sum(retirees)
	sort gender age_ret

	generate double retirement_prob_eligible = retirees / at_risk

//	Keep the ages of the retirement database
	rename age_ret age
	keep if inrange(age, `min_age', `max_age')
	keep gender age retirees at_risk retirement_prob_eligible
	order gender age retirees at_risk retirement_prob_eligible

	list, noobs sepby(gender)

//	Compare with the hazards of the age-only model (affiliates and pensioners)
	preserve
		capture import delimited "`retiredir'/retirement_eligible_rates_`country'_ANNUAL_DATA_VERY_LOW_AGE_ONLY.csv", clear
		if _rc == 0 {
			rename retirement_prob_eligible hazard_age_only
			tempfile ageonly
			save `ageonly'
		}
	restore
	capture merge 1:1 gender age using `ageonly', nogenerate keep(1 3)
	if _rc == 0 {
		display as text _n "Hazard estimated on the pensioner database (retirement_prob_eligible) and on the affiliates and pensioners (hazard_age_only)"
		list gender age retirement_prob_eligible hazard_age_only, noobs sepby(gender)
		drop hazard_age_only
	}

//	Cumulative share of an eligible cohort that has retired by each age
	sort gender age
	by gender: generate double cum_retired = 1 - exp(sum(ln(1 - retirement_prob_eligible)))
	display as text _n "Cumulative share retired by each age (all of a cohort retires by the oldest age of the pensioner file)"
	list gender age cum_retired, noobs sepby(gender)
	drop cum_retired

//	Export
	cd "`retiredir'"
	export delimited using "`hazard_csv'.csv", replace
	display as result _n "Saved `hazard_csv'.csv"
