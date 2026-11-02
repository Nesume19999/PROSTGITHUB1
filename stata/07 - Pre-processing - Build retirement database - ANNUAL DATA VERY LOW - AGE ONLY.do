/*******************************************************************************
Title: 			Build the retirement database (eligible affiliates and old-age retirees) - ANNUAL DATA VERY LOW
Author: 		Duncan MacDonald
Date created: 	October 6th, 2026
Description:	For building PROST v2 pension model (Revised)

Purpose:
	Builds the cell-level database used by the retirement model
	("08 - Pre-processing - Estimate retirement rates - ANNUAL DATA VERY LOW.do").
	For every gender x birth cohort x year it computes
		(i)  the number of affiliates who were ELIGIBLE for an old-age pension, and
		(ii) the number of those who actually RETIRED that year,
	with both counts corrected for mortality, so retirement_rate = retired / eligible.


The data problem:
	The affiliate database (annual_MEX) is NOT a panel. It is a cross-section with a
	career history: everyone in it is still an affiliate in the latest year, i.e. they
	have NOT retired. Anyone who retired in an earlier year simply is not in it. So,
	for a year t, the affiliate file only shows the "stayers" - those eligible at t who
	did not retire in t, nor in any later year up to the latest year.

	The people who did retire are in the pension database (pensioners_MEX), which
	records age (in the base year), gender and start year of every pension in payment.
	We therefore reconstruct the population at risk of retiring (for each cohort):

		eligible(t) = stayers(t)  +  sum over s>=t of retirees(s)

	stayers(t)  : affiliates in the affiliate file eligible in year t (age >= earliest
	              retirement age AND contributions >= minimum), scaled up to the
	              population (the affiliate file is a sample - see below)
	retirees(s) : old-age pensions that started in year s, for the same cohort. These
	              people were all eligible in year t <= s (eligibility is never lost).

	retirement_rate(t) = retirees(t) / eligible(t)    [discrete-time hazard]


Mortality correction:
	Both files only contain people who are ALIVE in the base year. Someone who was
	eligible in year t but died before the base year is in neither file. We use the
	cohort survival function S(start of year) from the observed mortality rates:

		f(t) = S(base year) / S(t)     = probability of surviving from t to the base year

	Counts alive in the base year are divided by f(t) to restate them at the start of
	year t:    eligible_t = pool_alive / f(t)      retirees_t = retirees_alive / f(t)
	(a retiree in year s>t is also divided by f(t) when counted in the year-t pool,
	because f(t->s) * f(s) = f(t)).
	Note: within a single cohort cell the same factor applies to numerator and
	denominator, so the RATE is unchanged by the correction, but the LEVELS (number
	eligible, number retiring) are correct, and any later aggregation across cells
	with different survival is correctly weighted.


Sample scaling:
	annual_MEX is a sample of the affiliate universe, while pensioners_MEX is the
	full count of pensions. The two must be on the same scale or the rate is wrong.
	By default the scaling factor is calibrated BY GENDER on ages 25-54 in the latest
	year (before anyone can retire) by comparing the sample with the aggregate number
	of affiliates (numA) in "001-Data Aggregates.dta". Set calibrate_scale = 0 and
	fill in manual_scale_* if you know the sampling fraction.


Identification limits (read before interpreting results):
	1. The affiliate file stops at the latest year and, in practice, at the oldest
	   cohort still affiliated. Cohorts that are older than the oldest age observed in
	   the latest year have no stayers, so their rate cannot be identified (it would be
	   100% by construction). These cohorts are dropped. The rate is therefore
	   identified for ages between the earliest retirement age and the maximum age in
	   the latest year, and only for years in which these cohorts were that old.
	2. Pensioners have no wage / contribution-density information, so the
	   individual-level predictors of the transition model (wage decile, density decile,
	   spell length, los_gap...) cannot be attached to the people who retired. The
	   database is therefore built by cohort cells with predictors that are known for
	   both groups: age, gender, calendar year, and statutory retirement ages.
	3. Anyone eligible who left the pool without an old-age pension (disability
	   pension, withdrawal) is treated as a stayer or is ignored; this is minor.
	4. If the last pension start year is a partial year, retirement in that year is
	   understated.


Source for the affiliate data: annual_MEX.dta  (collapse of the longitudinal microdata)
	If starting from "2 Input from client - longitudinal microdata about affiliates.dta"
	first collapse it to annual: (sum) dens (max) aux los iacc (mean) wage by id year.


Output:
	retirement_database_MEX.dta  [Input folder]  - one row per gender x cohort x year


*******************************************************************************/

//	INITIALIZATION
	clear all
	pause on
	set trace off

//	Country iso3 code
	local country  = "MEX"

//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local indir		 	= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local mortdir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\mortality_obs"

//	Name of input data
	local annual_data 	 = "annual_`country'"				// Affiliate cross-section with career history
	local long_data  	 = "2 Input from client - longitudinal microdata about affiliates.dta"	// [Alternative - collapse to annual first]
	local pension_data	 = "pensioners_`country'"			// Pension stock in the base year (all pension types)
	local mortality_data = "mortality_obs_`country'.csv"	// Observed mortality rates (wide by year)
	local aggregate_data = "001-Data Aggregates"			// Aggregate number of affiliates (numA) - used for scaling

//	Name of output data
	local retirement_db		 = "retirement_database_`country'_AGE_ONLY"

//	Parameters of the current pension system
//	Must be the same as in "04 - Pre-processing - Estimate transitions rates"
	local retage_earliest = 60				// Easliest possible retirement age - (Cesantía en Edad Avanzada)
	local retage_male = 65 					// Male retirement age
	local retage_female = 65				// Female retirement age
	local retcont_min = (750 / 52) * 12		// Minimum contribution threshold (in months)

//	Sample scaling parameters
	local calibrate_scale = 1				// 1 = calibrate affiliate sample to aggregate numA; 0 = use manual scale
	local manual_scale_1  = 1				// Males: number of affiliates represented by each person in annual_data
	local manual_scale_2  = 1				// Females: number of affiliates represented by each person in annual_data
	local cal_age_min     = 25				// Age range used for the calibration (people too young to be retiring)
	local cal_age_max     = 54


********************************************************************************
//	STEP 1: Cohort survival rates (survival to the START of each year)

	cd "`mortdir'"
	import delimited "`mortality_data'", clear

	generate byte gender = .
	replace  gender = 1 if sex == "male"
	replace  gender = 2 if sex == "female"
	keep gender age y*

	reshape long y, i(gender age) j(year)
	rename y mortality_rate

	generate birth_year = year - age
	gsort gender birth_year year

	//	Survival through the end of each year, along the cohort diagonal
	generate double log_surv_inc = log(1 - mortality_rate)
	bysort gender birth_year (year): generate double cum_log_surv = sum(log_surv_inc)

	//	Survival to the START of the year = survival through the end of the year, less this year's own deaths
	generate double surv_start = exp(cum_log_surv - log_surv_inc)

	keep gender birth_year year surv_start
	tempfile survival
	save `survival', replace


********************************************************************************
//	STEP 2: Affiliates who are eligible for a pension (the "stayers")

	cd "`indir'"
	use id gender yob year dens los using "`annual_data'", clear

	summarize year
	local latest_year = r(max)

	generate age = year - yob
	generate birth_year = yob

	//	Oldest age observed in the latest year: cohorts older than this have no stayers
	summarize age if year == `latest_year'
	local max_age_latest = r(max)
	display as text "Latest year: `latest_year' | Oldest affiliate in latest year: `max_age_latest'"

	//	Number of sample affiliates by gender in the calibration age range
	preserve
		keep if year == `latest_year' & inrange(age, `cal_age_min', `cal_age_max')
		collapse (count) n_sample = id, by(gender)
		tempfile sample_count
		save `sample_count', replace
	restore

	//	Eligibility at the START of the year (contributions through the end of last year)
	generate los_start = los - dens
	generate byte eligible = (age >= `retage_earliest') & (los_start >= `retcont_min')
	keep if eligible == 1

	generate long one = 1
	collapse (sum) n_stay_sample = one, by(gender birth_year year)
	tempfile stayers
	save `stayers', replace


********************************************************************************
//	STEP 3: Scale the affiliate sample to the affiliate population

	//	Aggregate number of affiliates by gender in the calibration age range
	use "`aggregate_data'", clear
	keep if inrange(age, `cal_age_min', `cal_age_max')
	quietly summarize year
	if r(max) != `latest_year' {
		display as error "WARNING: aggregate data is for year " r(max) " but affiliate data ends in `latest_year'"
	}
	collapse (sum) n_aggregate = numA, by(gender)
	recast byte gender
	merge 1:1 gender using `sample_count', assert(3) nogenerate

	generate double scale = n_aggregate / n_sample
	if `calibrate_scale' == 0 {
		replace scale = `manual_scale_1' if gender == 1
		replace scale = `manual_scale_2' if gender == 2
	}
	list, noobs
	keep gender scale
	tempfile scale_factors
	save `scale_factors', replace


********************************************************************************
//	STEP 4: Old-age retirees from the pension database

	use "`pension_data'", clear

	//	Keep old-age pensions only
	capture confirm string variable pension_type
	if _rc decode pension_type, generate(pension_type_s)
	else   generate pension_type_s = pension_type
	keep if pension_type_s == "Old-age"

	//	Keep DB pensions only: at the ages where people retire (60+) practically all affiliates are in the
	//	DB (transition) plan (99% of contributors aged 60-64 in the aggregates; DC is <1% of old-age retirees
	//	in the cohorts used here). The stayers are therefore treated as DB as well.
	capture confirm string variable pension_class
	if _rc decode pension_class, generate(pension_class_s)
	else   generate pension_class_s = pension_class
	count
	local n_oa = r(N)
	count if pension_class_s != "DB"
	display as text "Old-age pensions that are not DB (dropped): " r(N) " of `n_oa'"
	keep if pension_class_s == "DB"

	//	The pension stock is observed in the base year: ages are as of that year
	summarize startyear
	local pension_baseyear = r(max)
	if `pension_baseyear' != `latest_year' {
		display as error "WARNING: last pension start year (`pension_baseyear') differs from latest affiliate year (`latest_year')"
	}

	drop if missing(age)
	generate age_start  = age - (`pension_baseyear' - startyear)	// Age when the pension started
	generate birth_year = `pension_baseyear' - age

	//	Those who started a pension before the earliest retirement age cannot be placed in the eligible pool
	count
	local n_all = r(N)
	count if age_start < `retage_earliest'
	display as text "Old-age pensions starting before age `retage_earliest' (dropped): " r(N) " of `n_all'"
	drop if age_start < `retage_earliest'

	//	Only cohorts that can be matched with stayers in the affiliate file
	count if birth_year < `latest_year' - `max_age_latest'
	display as text "Old-age pensions of cohorts older than any affiliate in `latest_year' (dropped): " r(N)
	drop if birth_year < `latest_year' - `max_age_latest'

	recast byte gender
	rename startyear year
	generate long one = 1
	collapse (sum) n_retired_alive = one, by(gender birth_year year)
	tempfile retirees
	save `retirees', replace


********************************************************************************
//	STEP 5: Combine stayers and retirees into a complete cohort x year grid

	use `stayers', clear
	merge 1:1 gender birth_year year using `retirees', nogenerate
	replace n_stay_sample 	  = 0 if missing(n_stay_sample)
	replace n_retired_alive   = 0 if missing(n_retired_alive)

	//	Fill the gaps so that every cohort has every year from first eligibility to the latest year
	generate long panel = gender * 10000 + birth_year
	xtset panel year
	tsfill
	replace gender 	   		  = floor(panel / 10000) if missing(gender)
	replace birth_year 		  = panel - gender * 10000 if missing(birth_year)
	replace n_stay_sample 	  = 0 if missing(n_stay_sample)
	replace n_retired_alive   = 0 if missing(n_retired_alive)
	drop panel

	generate age = year - birth_year
	keep if age >= `retage_earliest'
	keep if year <= `latest_year'

	//	Scale the stayers to the population
	merge m:1 gender using `scale_factors', assert(2 3) keep(3) nogenerate
	generate double n_stay_alive = n_stay_sample * scale

	//	Retirees that will still retire in this year or LATER (they are still in the eligible pool now)
	gsort gender birth_year -year
	by gender birth_year: generate double n_retired_from_now = sum(n_retired_alive)

	//	Everyone alive in the base year who was in the eligible pool at the start of this year
	generate double n_pool_alive = n_stay_alive + n_retired_from_now


********************************************************************************
//	STEP 6: Mortality correction - restate counts at the start of each year

	merge m:1 gender birth_year year using `survival', keep(1 3) keepusing(surv_start) nogenerate
	rename surv_start surv_start_t

	//	Survival of each cohort to the start of the base year
	preserve
		use `survival', clear
		keep if year == `latest_year'
		rename surv_start surv_start_base
		keep gender birth_year surv_start_base
		tempfile survival_base
		save `survival_base', replace
	restore
	merge m:1 gender birth_year using `survival_base', keep(1 3) nogenerate

	//	Probability of surviving from the start of year t to the base year
	generate double surv_to_base = surv_start_base / surv_start_t
	label variable surv_to_base "Probability of surviving from start of year to the base year"

	//	Number (at the start of year t) of eligible affiliates, and of people who retire in year t
	generate double eligible 	= n_pool_alive 		/ surv_to_base
	generate double retired 	= n_retired_alive 	/ surv_to_base
	generate double stayers 	= n_stay_alive		/ surv_to_base

	generate double retirement_rate = retired / eligible
	label variable eligible 		"Affiliates eligible for an old-age pension at start of year (mortality-corrected)"
	label variable retired 			"Eligible affiliates that took old-age retirement in the year (mortality-corrected)"
	label variable stayers 			"Eligible affiliates who have not (yet) retired by the base year (mortality-corrected)"
	label variable retirement_rate 	"Share of eligible affiliates retiring in the year"

	//	For comparison: naive rate which ignores people who retire in later years
	generate double retirement_rate_naive = n_retired_alive / (n_stay_alive + n_retired_alive)
	label variable retirement_rate_naive "Naive rate: ignores the future retirees in the pool [DO NOT USE]"


********************************************************************************
//	STEP 7: Predictors that are known for both groups

//	Normal retirement age
	generate retage_normal = `retage_male'
	replace  retage_normal = `retage_female' if gender == 2
	generate byte age_at_normal  = (age >= retage_normal)
	generate byte age_at_earliest = (age == `retage_earliest')
	generate years_since_earliest = age - `retage_earliest'
	generate year_trend = year - `latest_year'

	label variable age_at_normal 		"Age is at or above the normal retirement age"
	label variable age_at_earliest 		"Age is the earliest retirement age"
	label variable years_since_earliest "Years since earliest retirement age"
	label variable year_trend 			"Calendar year relative to the latest year"

	//	Drop any cells where there is nothing to estimate
	drop if eligible <= 0 | missing(eligible)
	order gender birth_year year age eligible retired retirement_rate stayers

	compress
	cd "`indir'"
	save "`retirement_db'", replace


********************************************************************************
//	DIAGNOSTICS

	display _newline as text "Eligible affiliates and share retiring - by year"
	preserve
		collapse (sum) eligible retired stayers n_retired_alive n_stay_alive, by(year)
		generate retirement_rate = retired / eligible
		format eligible retired stayers %12.0fc
		format retirement_rate %6.3f
		list year eligible retired retirement_rate, noobs sep(0)
	restore

	display _newline as text "Eligible affiliates and share retiring - by age and gender (pooled over years)"
	preserve
		collapse (sum) eligible retired, by(age gender)
		generate retirement_rate = retired / eligible
		format eligible retired %12.0fc
		format retirement_rate %6.3f
		list age gender eligible retired retirement_rate, noobs sep(0)
	restore

	//	Sanity checks
	assert retirement_rate >= 0 & retirement_rate <= 1
	assert surv_to_base > 0 & surv_to_base <= 1
	summarize retirement_rate retirement_rate_naive surv_to_base

********************************************************************************
