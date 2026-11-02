/*******************************************************************************
Title: 			Estimate retirement rates of eligible affiliates - ANNUAL DATA VERY LOW
Author: 		Duncan MacDonald
Date created: 	October 6th, 2026
Description:	For building PROST v2 pension model (Revised)

Note: Estimates the annual probability that an affiliate who is ELIGIBLE for an
	  old-age pension actually retires (takes the pension) in that year. The
	  estimation database is built by
	  "07 - Pre-processing - Build retirement database - ANNUAL DATA VERY LOW.do",
	  from the affiliate file combined with the pension file. Read the header of that
	  file for how the eligible population is reconstructed and corrected for mortality.

	  The data are cohort cells (gender x birth year x year), each with the
	  mortality-corrected number of eligible affiliates ("eligible") and the number of
	  them who retired ("retired"). The model is a discrete-time hazard model:

	glm retired c.age##c.age i.gender i.age_at_earliest i.age_at_normal c.year_trend, family(binomial eligible) link(cloglog) vce(robust)

Note: Same functional form as the transition models in
	  "04 - Pre-processing - Estimate transitions rates - ANNUAL DATA VERY LOW.do"
	  (GLM, binomial family, cloglog link: a discrete-time proportional hazards model,
	  predictions stay within [0,1]) and uses the same age, age-squared and gender
	  predictors. The retirement_age indicator of the transition models is replaced by
	  two indicators, because every person in the sample is already past the earliest
	  retirement age:
		age_at_earliest : age is the earliest retirement age (spike when it becomes possible)
		age_at_normal   : age is at/above the normal retirement age

Note: The transition-model predictors that describe an individual's career (wage
	  decile, density decile, spell length, los_gap, no_hope) are NOT used. The pension
	  file has no career information for those who retired, so these predictors would be
	  observed only for those who did not retire. Eligibility (los_gap == 0) is already
	  imposed on the denominator. To add career predictors, the pension file needs a
	  wage or contribution history (or a benefit-based proxy).

Note: Identification range. The rate can only be estimated for ages up to the oldest
	  age that is still observed in the latest year of the affiliate file (cohorts older
	  than that have no stayers). Predictions outside this range are extrapolations -
	  the exported table is restricted to the observed range. The projection model
	  should use `too_old_to_retire' to force retirement at the older ages.

Note: The standard errors treat each cohort cell as an independent observation and
	  use robust variance. Stayers are scaled up from a sample, so the cell counts have
	  more weight than their sample information justifies; the confidence intervals are
	  therefore somewhat too narrow.

Output:
	retirement_model_MEX_ANNUAL_DATA_VERY_LOW.ster		[transitions folder]
	retirement_eligible_rates_MEX_ANNUAL_DATA_VERY_LOW.csv	[retirement folder]

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
	local transdir		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\transitions"
	local retiredir		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\retirement"

//	Name of input data
	local retirement_db	= "retirement_database_`country'_AGE_ONLY"

//	Simulation parameters
	local years_avg   = 10  	// Number of years of back data to use (all of the retirement data are used if smaller)

//	Output model name
	local retirement_model	= "retirement_model_`country'_ANNUAL_DATA_VERY_LOW_AGE_ONLY"
	local retirement_csv	= "retirement_eligible_rates_`country'_ANNUAL_DATA_VERY_LOW_AGE_ONLY"


********************************************************************************
// 	Open the retirement database
	cd "`indir'"
	use "`retirement_db'", clear

	summarize year
	local latest_year = r(max)
	summarize age
	local max_age_obs = r(max)
	local min_age_obs = r(min)

	keep if year > `latest_year' - `years_avg'

	display as text "Years: " `latest_year' - `years_avg' + 1 " to `latest_year' | Ages `min_age_obs' to `max_age_obs' | Cells: " _N


********************************************************************************
//	Estimate the retirement hazard
//	Binomial GLM with cloglog link. The denominator is the (mortality-corrected)
//	number of eligible affiliates at the start of the year.

//	Model 1: Age and gender only
	glm retired c.age##c.age i.gender, family(binomial eligible) link(cloglog) vce(robust)
	estimates store m_age

//	Model 2: Plus the statutory retirement-age indicators
	glm retired c.age##c.age i.gender i.age_at_earliest i.age_at_normal, family(binomial eligible) link(cloglog) vce(robust)
	estimates store m_ages

//	Model 3: Plus a calendar-year trend [MAIN MODEL]
	glm retired c.age##c.age i.gender i.age_at_earliest i.age_at_normal c.year_trend, family(binomial eligible) link(cloglog) vce(robust)
	estimates store m_main

//	Model 4: Plus a gender-specific pattern at the earliest retirement age
	glm retired c.age##c.age i.gender i.age_at_earliest i.age_at_normal c.year_trend i.gender#i.age_at_earliest, family(binomial eligible) link(cloglog) vce(robust)
	estimates store m_gender

	estimates stats m_age m_ages m_main m_gender

//	Save the main model
	local estimates_used = "m_ages"
	estimates restore `estimates_used'
	cd "`transdir'"
	estimates save "`retirement_model'", replace


********************************************************************************
//	Validation: predicted versus actual number of retirees

	estimates restore `estimates_used'
	//	Note: With a binomial denominator, predict mu returns the expected COUNT, so we
	//	invert the cloglog link from the linear predictor to get the probability.
	predict double xb_hat, xb
	generate double retirement_rate_hat = 1 - exp(-exp(xb_hat))
	generate double retired_hat = retirement_rate_hat * eligible

	display _newline as text "Actual vs predicted retirement - by age"
	preserve
		collapse (sum) eligible retired retired_hat, by(age)
		generate rate_actual = retired / eligible
		generate rate_hat    = retired_hat / eligible
		format eligible retired retired_hat %12.0fc
		format rate_actual rate_hat %6.3f
		list age eligible retired retired_hat rate_actual rate_hat, noobs sep(0)
	restore

	display _newline as text "Actual vs predicted retirement - by year"
	preserve
		collapse (sum) eligible retired retired_hat, by(year)
		generate rate_actual = retired / eligible
		generate rate_hat    = retired_hat / eligible
		format eligible retired retired_hat %12.0fc
		format rate_actual rate_hat %6.3f
		list year eligible retired retired_hat rate_actual rate_hat, noobs sep(0)
	restore

	display _newline as text "Actual vs predicted retirement - by gender"
	preserve
		collapse (sum) eligible retired retired_hat, by(gender)
		generate rate_actual = retired / eligible
		generate rate_hat    = retired_hat / eligible
		list gender eligible retired retired_hat rate_actual rate_hat, noobs sep(0)
	restore


********************************************************************************
//	Export the predicted retirement probability of eligible affiliates by age and gender
//	Evaluated in the latest year, only over the observed age range.

	clear
	local n_rows = (`max_age_obs' - `min_age_obs' + 1) * 2
	set obs `n_rows'
	generate byte gender = mod(_n - 1, 2) + 1
	generate age = `min_age_obs' + floor((_n - 1) / 2)
	generate year_trend = 0
	generate eligible = 1		// Dummy: glm predict needs the binomial denominator variable to exist

	//	Statutory retirement ages [Must be the same as in the database build]
	local retage_earliest = 60
	local retage_male = 65
	local retage_female = 65
	generate byte age_at_earliest = (age == `retage_earliest')
	generate byte age_at_normal   = (age >= `retage_male')   if gender == 1
	replace  age_at_normal        = (age >= `retage_female') if gender == 2

	estimates restore `estimates_used'
	predict double xb_hat, xb
	generate double retirement_prob_eligible = 1 - exp(-exp(xb_hat))
	label variable retirement_prob_eligible "Annual probability that an eligible affiliate retires"

	keep age gender retirement_prob_eligible
	sort gender age
	list, noobs sepby(gender)

	cd "`retiredir'"
	export delimited "`retirement_csv'.csv", replace


********************************************************************************
