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

Note: ANNUAL DATA VERY LOW VERSION
	This version runs the projection on an ANNUAL time step instead of a monthly one.
	There is no `month` variable at all - each affiliate has exactly one row per projection
	year, indexed by `year` alone. Stage 5 joins in a small snapshot of last year's key
	values (dens, los, loa, spell_length, wage, wage_decile), taken before this year's row
	is created, as `*_last` variables - dropped again once Stage 5 is done with them.
	`dens` is the NUMBER OF MONTHS WORKED IN THE YEAR (0-12), not a monthly 0/1 flag.
	Two monthly hazard rates (transition_in/transition_out, from job_entry_model/
	job_exit_model - see "04 - Pre-processing - Estimate transitions rates - ANNUAL DATA
	VERY LOW.do") are estimated on annual data with `density_decile` added as a covariate.
	Stage 5 simulates a 12-step employment-status Markov chain in-memory - still one row
	per person-year, no monthly panel expansion - to turn the two hazards into this year's
	`dens`, which gives genuine within-year employment persistence at the annual dataset's
	grain (and its ~20x speedup over a monthly model).

Note: PENSION PULL OPTION
	`pension_pull' (see the transition model settings) selects the labour-market transition models:
		0 = Original models (job_entry_model/job_exit_model).
		1 = Pension pull models (the same models re-estimated in "04 - Pre-processing - Estimate
		    transitions rates - ANNUAL DATA VERY LOW PULL.do"). They are estimated only on
		    person-years in which the person CANNOT yet retire, and add the distance to pension
		    eligibility (years_to_elig, in bands yte_band) as a predictor, so people who are close
		    to being able to retire are less likely to leave formal work (years_to_elig and the
		    service still needed, sg_band, are predictors). People who can already retire are treated as if they were within one year of
		    eligibility (the nearest band with data); their decision to retire is handled by
		    `retirement_rule'.

Note: PENSION INDEXATION AND THE MINIMUM PENSION (DB)
	* A pension is first indexed in the year AFTER it starts (`index_in_start_year' = 0, the default). Set it to 1
	  to also index it in the year it starts.
	* The government top-up to the minimum pension (gov_minpen_subsidy) of a pensioner is indexed with the pension
	  (DC top-ups only if the DC pension is indexed, `dc_annuity_indexed').
	* Pensions in payment are indexed with pension_index = (alpha1 x CPI + alpha2 x real wage + alpha3 x anchor)/100
	  and are not topped up to the current minimum pension. Set alpha2 = alpha3 = 0 in the indexation sheet for CPI-only indexation.
	* The DB minimum pension for NEW retirees is read year by year from the min_pension sheet while the sheet has a row
	  for the year (so it can be tied to a wage unit such as the minimum wage: minpen_base = number of wage units,
	  minpen_base_unit = the unit). After the last year of the sheet it grows with the minimum-pension index (CPI-type) or,
	  if the optional column minpen_index_wage is 1, with nominal wage growth (use it when the minimum is tied to a wage).

Note: RETIREMENT ANCHOR OPTION
	`retirement_anchor' = 1 fixes the NUMBER of new retirees in every projection year at a share of
	the retirement-eligible affiliates (`retirement_share', default 12.5%). Eligible = alive, still
	affiliated, meets the pension eligibility conditions and is at/above the earliest retirement age
	(people who reach `too_old_to_retire' retire anyway and are not counted). The retirement rule
	still decides WHO retires: with `retirement_rule' = 2 people are selected with a propensity
	proportional to the retirement-model probability; with `retirement_rule' = 1 every eligible
	person has the same propensity. The number is exact (to the sample): the people with the
	lowest random draws, scaled by the propensity, retire.
	Default share (12.5%): the share of the retirement-eligible affiliates that retires each year
	when the retirement rates by age and gender are applied to the age mix of the projection's
	eligible pool. The rates are the new old-age pensions (pensioner database) divided by the stock of
	eligible affiliates a year earlier (affiliate database) - see "09 - Pre-processing - Estimate
	retirement rates from affiliate stocks - ANNUAL DATA VERY LOW.do" - and, for ages 65 to 74
	where the affiliate database has no data, by the aggregate stock of affiliates (upper bound).
	The average of the yearly shares of 2015-2020 (22%) is NOT used: those years are a young
	pool (ages 60 to 65), whereas more than half of the projection's eligible pool is aged 65+.

Note: RETIREMENT RULE OPTION
	`retirement_rule' (see Simulation parameters) selects how affiliates (DB and DC) decide to retire:
		1 = Original rule: a person retires as soon as they are eligible and working longer
		    is an implicit tax on earnings (Gruber-Wise rule). Retirement is driven by eligibility.
		2 = Retirement model: of the affiliates who are eligible and at/above the earliest
		    retirement age, a share retire each year equal to the probability predicted by the
		    model estimated in "07/08 - Pre-processing - ... retirement ... - AGE ONLY.do"
		    (age, age-squared, gender, earliest/normal retirement-age indicators). Those who do
		    not retire stay in the pool and face the same draw the next year. The "too old"
		    rules apply in both options.
	The model was estimated on DB retirees; it is applied to DC affiliates as well (using the
	DC earliest/normal retirement ages and DC eligibility), with no separate DC behavior.

*******************************************************************************/

//	INITIALIZATION
	clear all
	pause on
	set trace off
	timer on 1

// 	SETS THE SEED OF THE RANDOM NUMBER GENERATOR
//	Note: Any seed works the same. 
//	The idea is to set it to one specific value so to have the same resuts when the model is re-run
	set seed 2

//	MATA FUNCTION: employment-rate multiplier of the labour-market anchor (Stage 5).
//	Finds log(multiplier) such that the mean year-end employment probability equals the target. The function is increasing and
//	continuous in log(multiplier), so the Illinois (regula falsi) root finder converges in about 10 evaluations instead of the
//	30 passes of a bisection. Each evaluation is vectorised in Mata (no new Stata variables). Result: scalar anchor_logmult.
	mata:
	real scalar anchor_eval(real colvector p, real colvector tin, real colvector tout, real colvector one, real scalar x, real scalar target)
	{
		real colvector ta, to, pss, rr, ravg, pend
		real scalar m
		m    = exp(x)
		ta   = rowmin((rowmax((tin * m,  0.0001 * one)), 0.9999 * one))
		to   = rowmin((rowmax((tout / m, 0.0001 * one)), 0.9999 * one))
		pss  = ta :/ (ta + to)
		rr   = one - ta - to
		ravg = (one - rr:^12) :/ (12 * (one - rr))
		pend = pss + (p - pss) :* ravg
		return(mean(pend) - target)
	}

	void anchor_search(string scalar vp, string scalar vtin, string scalar vtout, real scalar target)
	{
		real colvector p, tin, tout, one
		real scalar a, b, c, fa, fb, fc, i, side
		st_view(p=., ., vp)
		st_view(tin=., ., vtin)
		st_view(tout=., ., vtout)
		one = J(rows(tin), 1, 1)
		a = -10
		b = 10
		fa = anchor_eval(p, tin, tout, one, a, target)
		fb = anchor_eval(p, tin, tout, one, b, target)
		c = (a + b) / 2
		if (fa >= 0) c = a			// target below what the lowest multiplier gives
		else if (fb <= 0) c = b		// target above what the highest multiplier gives
		else {
			side = 0
			for (i = 1; i <= 100; i++) {
				c  = (fa * b - fb * a) / (fa - fb)
				fc = anchor_eval(p, tin, tout, one, c, target)
				if (abs(fc) < 1e-12 | abs(b - a) < 1e-12) break
				if (fc * fb > 0) {
					b = c
					fb = fc
					if (side == -1) fa = fa / 2
					side = -1
				}
				else {
					a = c
					fa = fc
					if (side == 1) fb = fb / 2
					side = 1
				}
			}
		}
		st_numscalar("anchor_logmult", c)
	}
	end

	
//	SPEED SETTINGS
	// Uses float variables rather than double - less space than double (increases speed)
	set type float	
	// Ensure that all processores are being used
	local max_processors = c(processors_max)
	set processors `max_processors'

//	SET THE SIMULATION NAME
	local simname 		= "Annual_Data_VeryLow_1pct_80years"
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
 	local baseyear_data  	 = "synthetic_affiliates_1pct_sample_annualized.dta"	// Detailed affiliate data in the base year - annualized synthetic data (see "00 - Convert synthetic baseyear from monthly to annual.do")
	local pensioners_data	 = "synthetic_pensioners_1pct_sample.dta"	// Detailed pensioner data in the base year - synthetic data derived from aggregates (pensioner file is unaffected by the monthly->annual change)
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
	*local lm_assumptions	 = "labor_market_assumptions.csv"			// Labour market assumptions over the projection (turnover_target, emp_rate_growth)
	local lm_assumptions	 = "labor_market_assumptions.csv"			// Labour market assumptions over the projection (turnover_target, emp_rate - direct employment-rate level target, 1 = 100%)
	*local index_assummptions = "indexation_assumptions_MEX.csv"			// No longer used: inflation (cpi), real wage growth (wage_growth - cpi) and the anchor (anchor) come from the wage growth file
	local wage_grow_data 	 = "wage_growth_MEX.csv"					// Assumed wage growth by year
	*local wage_grow_data 	 = "cpi_MEX.csv"							// Assumed wage growth by year

	
//	Transition model data (ANNUAL DATA VERY LOW VERSION)
//	job_exit_model/job_entry_model are the transition_out/transition_in hazard models,
//	estimated in "04 - Pre-processing - Estimate transitions rates - ANNUAL DATA VERY
//	LOW.do" with `density_decile' as a covariate. Stage 5 below simulates a 12-step
//	Markov chain from these two hazards to draw this year's dens.
	local job_entry_model 	 = "job_entry_model_MEX_10_ANNUAL_DATA_VERY_LOW"	// transition_in hazard (monthly re-entry probability)
	local job_exit_model 	 = "job_exit_model_MEX_10_ANNUAL_DATA_VERY_LOW"	// transition_out hazard (monthly exit probability)

//	Pension pull: 0 = original transition models; 1 = models that depend on how close a person is to pension eligibility
	local pension_pull		 = 0
	if `pension_pull' == 1 {
		local job_entry_model = "job_entry_model_MEX_10_ANNUAL_DATA_VERY_LOW_PULL"
		local job_exit_model  = "job_exit_model_MEX_10_ANNUAL_DATA_VERY_LOW_PULL"
	}

//	Unused alternative model specifications, kept for reference - not loaded below.
	local tobit_model 		 = "tobit_model_MEX_10_ANNUAL_DATA"			// tobit: distribution of months worked (0-12), censored at [0,12]
	local betabin_model		 = "betabin_model_MEX_10_ANNUAL_DATA" 		// beta-binomial: distribution of months worked (0-12), censored at [0,12]
	local hurdle_zero_model	 = "hurdle_zero_model_MEX_10_ANNUAL_DATA"		// hurdle stage 1: P(dens==0)
	local hurdle_full_model	 = "hurdle_full_model_MEX_10_ANNUAL_DATA"		// hurdle stage 2: P(dens==12 | dens>0)
	local interior_betabin_model = "interior_betabin_model_MEX_10_ANNUAL_DATA"	// hurdle stage 3: beta-binomial on the interior (0<dens<12) sample only

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
	local histograms = 1					// Toggle on and off histograms
	
	local working_age_min	= 15			// Minimum age to be considered working age
	local working_age_max	= 64			// Maximum age to be considered working age
	*local wage_adjustment	= 9878.469 / 7048.628	// Wage adjustment to bring 2020 data to 2024 baseyear (monthly earnings growth from the ILO)
	local wage_adjustment	= 1				// Because we are using the synthetic data that match average wages, we do not adjust wages [Aggregate data is from 2024]
	local too_old_to_retire = 75			// Age at which people retire if they haven't already

//	Retirement decision rule
//	1 = Original rule (eligibility + implicit tax); 2 = Retirement model (annual probability of retiring among those eligible - DB and DC affiliates)
	local retirement_rule	= 2 // 1
	local retirement_model	= "retirement_model_MEX_ANNUAL_DATA_VERY_LOW_AGE_ONLY"	// Estimates saved by "08 - Pre-processing - Estimate retirement rates - ANNUAL DATA VERY LOW - AGE ONLY.do"
	local retmodel_min_age	= 60			// Ages are clamped to the range in which the model was estimated (below this age the model is never applied)
	local retmodel_max_age	= 65			// Above this age the rate at this age is used (the quadratic age term cannot be extrapolated); `too_old_to_retire' still applies

//	Retirement anchor: 0 = off; 1 = the number of new retirees each year is a share of the retirement-eligible affiliates
	local retirement_anchor	= 0
	local retirement_share	= 0.125			// Share of the retirement-eligible affiliates who retire each year (default: 12.5%)

//	Pension indexation timing: 0 = a pension is first indexed in the year AFTER it starts; 1 = also indexed in the year it starts
	local index_in_start_year = 0

//	Option right of the transition generation (DB class, entered before the DC reform):
//	1 = at retirement they take the higher of the DB pension and the DC (account) pension; people who take the DC pension
//	    are moved to pension_class = 2 and the switch is recorded in pension_class_switch (1 = DB to DC)
//	0 = no option (DB class always take the DB pension)
	local option_right = 1

//	Fund return: 1 = dc_return_gross in the workbook is a REAL return (converted to nominal with the inflation of the year, the account is nominal);
//	0 = it is already nominal
	local dc_return_is_real = 1

//	POLICY THRESHOLDS AFTER THE LAST YEAR OF THE POLICY TABLES
//	Contribution brackets (employer, employee, government), and the wage groups of the defined-benefit formula, are defined in the policy tables up to a
//	last year, in pesos of that year. index_thresholds = 1 moves them with nominal wage growth after the last year of their table (as the covered
//	wage ceilings and the minimum pensions are), so that a worker keeps the same position in the brackets when wages grow. 0 = they stay in
//	the pesos of the last table year (a worker then drifts into the top bracket as wages grow).
	local index_thresholds = 1
	local dc_thr_scale_er  = 1
	local dc_thr_scale_ee  = 1
	local dc_thr_scale_gov = 1
	local db_thr_scale     = 1

//	OUTPUT CHARTS
//	output_charts = 1 builds the standard charts of the run at the end of the run: the graphs (.png and .gph) and, for each chart, an
//	Excel file with the data behind it. They are saved in the folder charts_dir/simname. The builder is "1b - PROSTv2 - Output charts.do"
//	(it can also be run on its own on the files of a finished run). Charts: affiliates and pensioners, old-age pensions in payment and average
//	pension by system, age distribution of new retirees, share at the minimum pension, payments and expenditure by system and component (share of GDP),
//	top-ups by wage quintile / decile, lump sums, replacement rates, lifetime pension.
	local output_charts   = 0
	local charts_dir      = "C:\Users\Duncan\OneDrive\World Bank\Generic\Output\Charts"	// Folder for the charts (a sub-folder with the simulation name is created in it)
	local chart_script    = "C:\Users\Duncan\OneDrive\World Bank\Generic\1b - PROSTv2 - Output charts.do"
	local gdp_data        = "Defaults/gdp/gdp_`country'.csv"		// GDP file in the Input folder (IMF WEO, see Defaults/gdp/Source.txt). Needed for the two GDP charts only; years after the last year of the file are extended in the chart builder
	local chart_label_db  = "Law 73"				// Names of the two systems in the charts
	local chart_label_dc  = "Law 97"
	local chart_years     = ""						// Years of the age-distribution charts, for example "2030 2050 2080". Empty = first, middle and last year
	local chart_gdp_real_growth = 2					// Real GDP growth (percent a year) after the last year of the GDP file (WEO ends in 2031). Nominal GDP then grows by (1 + real growth) x (1 + inflation) - 1, with the inflation (cpi) of the wage growth input file




//	Labour market parameters
//	See Step 1.7
//	Note: the key anchors of emp_rate (a direct employment-rate level target) and turnover_target
//	are imported from user-maintained csv files




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
// 	local dc_annuity_rate     = 0.035	// REAL discount rate; converted to a nominal rate with the assumed inflation of the year
// 	local dc_annuity_indexed  = 0		// 1 = index DC pension post-retirement; 0 = fixed nominal
//
//	
	

	
	
	
*quietly{	
********************************************************************************


timer on 2
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
		
			// Only take a sample of the affiliates [TODO: Consider a stratified sample]
			// The sample is drawn BEFORE expanding (expanding to the whole population of new affiliates, about two million rows a year,
			// and sampling afterwards was the main cost of the initialization): the number of sampled affiliates of each age x gender
			// cell is new_affiliates x samplesize / 100, rounded systematically with a random start (unbiased, and the total is exact).
			generate double expected_n = new_affiliates * `samplesize' / 100
			generate double cum_n      = sum(expected_n)
			local u_start = runiform()
			generate long sampled_n    = floor(cum_n + `u_start') - floor(cum_n - expected_n + `u_start')
			drop if sampled_n < 1		// (expand keeps one copy of an observation whose count is below 1)
			expand sampled_n
			drop expected_n cum_n sampled_n

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
	local emp_rate_target_last = .
	forvalues yr = `startyear'/`endyear' {
		quietly summarize turnover_target if year == `yr'
		if r(N) > 0 {
			local turnover_`yr' = r(mean)
			local turnover_last  = r(mean)
		}
		else {
			local turnover_`yr' = `turnover_last'
		}
		// `emp_rate' is a direct employment-rate LEVEL target (1 = 100%), read fresh each year.
		quietly summarize emp_rate if year == `yr'
		if r(N) > 0 {
			local emp_rate_target_`yr' = r(mean)
			local emp_rate_target_last  = r(mean)
		}
		else {
			local emp_rate_target_`yr' = `emp_rate_target_last'
		}
		}


			
********************************************************************************
//	STEP 1.7
//	Load the labour market assumptions into memory
	cd "`transdir'"

	// Load the transition_in/transition_out hazard-rate models into memory (see
	// "04 - Pre-processing - Estimate transitions rates - ANNUAL DATA VERY LOW.do")
	estimates use "`job_exit_model'"
	estimates store job_exit_stored		// transition_out: monthly exit hazard

	estimates use "`job_entry_model'"
	estimates store job_entry_stored		// transition_in: monthly re-entry hazard

	// Load the retirement model (annual probability that an eligible affiliate retires) - only if it is used
	// (see "08 - Pre-processing - Estimate retirement rates - ANNUAL DATA VERY LOW - AGE ONLY.do")
	if `retirement_rule' == 2 {
		estimates use "`retirement_model'"
		estimates store retirement_stored
	}

	// Unused alternative model specifications, kept for reference - not loaded.
	*estimates use "`tobit_model'"
	*estimates store tobit_stored

	*estimates use "`betabin_model'"
	*estimates store betabin_stored

	*estimates use "`hurdle_zero_model'"
	*estimates store hurdle_zero_stored		// Stage 1: P(dens==0)

	*estimates use "`hurdle_full_model'"
	*estimates store hurdle_full_stored		// Stage 2: P(dens==12 | dens>0)

	*estimates use "`interior_betabin_model'"
	*estimates store interior_betabin_stored	// Stage 3: beta-binomial on 0<dens<12


********************************************************************************
//	STEP 1.8
//	Load the lifecycle wage growth rates into memory
	cd "`lifecycledir'"
	estimates use "`lifecycle_model'"
	estimates store lifecycle_stored
	
	
********************************************************************************
//	STEP 1.9
//	Load the indexation assumptions into memory
//	Inflation, real wage growth and the anchor variable are all drawn from the wage growth input file (`wage_grow_data'),
//	in percent a year:   pindex_inflation = cpi;   pindex_realwage = wage_growth - cpi;   pindex_anchor = anchor
//	(the separate indexation assumptions file is no longer used)
	cd "`wagegrowdir'"
	import delimited "`wage_grow_data'", clear
	rename year year_merge
	capture confirm variable anchor
	if _rc generate double anchor = 0
	replace anchor = 0 if missing(anchor)
	generate double pindex_inflation = cpi
	generate double pindex_realwage  = wage_growth - cpi
	generate double pindex_anchor    = anchor
	keep year_merge pindex_inflation pindex_realwage pindex_anchor
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
	// Reporting: running lists of each year's in-year reporting tempfiles (see
	// Stage 13 below) - combined into `inyear_affiliate_reporting_tot'/
	// `inyear_affiliate_reporting' with a single append AFTER the main loop ends,
	// instead of re-reading/appending/re-saving the whole growing file every year.
	local total_files_list = ""
	local breakdown_files_list = ""

	
	
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

	**********
	// Reporting: running lists of each year's pensioner in-year reporting
	// tempfiles (see pensioner Stage 4 below) - combined into
	// `inyear_pension_reporting_tot'/`inyear_pension_reporting' with a single
	// append after the pensioner loop ends.
	local pension_total_files_list = ""
	local pension_breakdown_files_list = ""
	




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
				di "Variable `v' for year `db_yr' and bracket `b': `db_`v'_`b'_`db_yr''"
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

	// Optional column: 1 = after the last year of the sheet the minimum for new retirees grows with nominal wage growth
	// (the minimum is tied to a wage unit); 0 or no column = it grows with the minimum-pension index
	capture confirm variable minpen_index_wage
	if _rc generate minpen_index_wage = 0
	replace minpen_index_wage = 0 if missing(minpen_index_wage)

	// Save each monthly income threshold as a local
	quietly levelsof year, local(db_minpen_yrs)
	foreach db_yr of local db_minpen_yrs {
		foreach v in minpen_base minpen_refwage minpen_adj1 minpen_adj2 minpen_index_wage 	///
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
timer off 2
timer on 3
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
	// The baseyear file's own `spell_length' uses an incompatible, larger scale (full
	// retrospective spell duration, never zero) than the lagged/annual definition this
	// file's Stage 5/6 update logic expects. Recompute a same-scale proxy instead: a
	// partial-year dens this year signals a fresh transition (spell_length=0);
	// otherwise approximate "months in the current unbroken spell" using los (if
	// currently fully employed) or loa-los (if currently idle). This assumes a
	// continuous career with no past transitions, which overstates spell_length for
	// anyone who really did have earlier transitions, but is on the correct scale and
	// unbiased in direction.
	generate byte new_spell_baseyear = (dens > 0 & dens < 12) | (dens == loa)
	replace spell_length = 0            if new_spell_baseyear
	replace spell_length = los          if !new_spell_baseyear & dens == 12
	replace spell_length = loa - los    if !new_spell_baseyear & dens == 0
	drop new_spell_baseyear


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
		histogram contribution_density, name(cod_baseyear, replace) yscale(range(0 5))
		histogram contribution_density, by(wage_decile_ref) name(cod_by_decile_baseyear, replace) yscale(range(0 15))
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
	generate years_to_elig 	= .			// Pension pull: years until the person can retire (earliest age AND minimum service)
	generate byte yte_band 	= .			// Pension pull: band of years_to_elig (1 = up to 1 year ... 6 = more than 10 years)
	generate byte sg_band 	= .			// Pension pull: band of the service still needed (0 = service met, 1 = up to 1 year ... 5 = more than 5 years)
	generate double yte_p1	= .			// Pension pull: piecewise-linear terms in years_to_elig (knots at 1, 3, 5, 10 years)
	generate double yte_p2	= .
	generate double yte_p3	= .
	generate double yte_p4	= .
	generate double yte_p5	= .
	generate double sg_years = .		// Pension pull: years of service still needed (capped at 5)
	generate pension_gap 	= .			// Years until eligible for pension (on basis of service or age, whichever is binding)
	generate implied_retage = .			// Implied age that person would be eligible for retirement (if fully contributing)
	generate group 			= .			// Merging group (1 = age constrainted, 2 = service constrained, 3 = no hope)
	generate age_merge 		= .			// For merging to transitions database (that has 3 groups in it) 
	generate service_gap 	= .			// For merging to transitions database (that has 3 groups in it) 
	generate exiter 		= .			// Flag: 1 = exiting formal work (dens > 0 last year, dens == 0 this year)
	generate reentrant 		= .			// Flag: 1 = reentering formal work (dens == 0 last year, dens > 0 this year)
	generate new_affiliate 	= .			// Flag: 1 = entering formal work for the first time
	generate work_full_year_prob = .	// Tobit-implied P(latent months worked >= 12) this year, calibrated to labour-market targets in Stage 5 (ANNUAL DATA)
	generate months 		= 12		// Beta-Binomial model: Number of months in year


	

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
	
	generate db_accrual_rate 		= .		// Annual accrual rate (not used in the replacement rate)
	generate db_standard_rate 		= .		// Basic rate of the wage group (rate at the minimum service requirement)
	generate db_min_service_req 	= .		// Minimum service reqirement
	generate db_accrual_max 		= .		// Maximum accrual rate
	generate db_early_penalty		= .		// Share of the pension lost per year of retirement before the normal age
	generate db_late_bonus 			= .		// Annual increment to the rate per year of service beyond the minimum requirement
	
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
	generate retire_on_tax			= .		// Decision rule for retiring (based on expected accrual of pension wealth; replaced by the retirement model if retirement_rule == 2)
	generate retire_prob			= .		// Annual probability of retiring predicted by the retirement model (retirement_rule == 2)
	generate minimum_pension		= .		// Flag: person recieves minimum pension
	generate gets_lumpsum			= .		// Flag: Person gets a lumpsum pension and is not eligible
	generate byte pension_class_switch = 0	// Option right: 1 = moved from DB (class 1) to DC (class 2) at retirement; 0 = no switch
	
	
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
	capture drop emp_rate
	join emp_rate turnover_target, from(`labor_market_assumptions_data') by(year) keep(1 3) nogenerate	// ftools version of merge [faster]
	local turnover_target = turnover_target		// Easier to have these as locals than as variables [only works if we only have one year in the DB]



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
	generate sample_pop 	 	= `samp' 							// Annual sample population count
	generate affiliates			= `affiliates' 						// Number of affilates
	generate employment      	= `emp'	/ 12						// Number of affiliates who are contributing ("working")
	generate employment_rate 	= 100 * employment / affiliates		// "Employment rate": Share of affiliates who are working
	generate unemployment    	= affiliates - employment			// Number of affiliates who are not contributing ("not working")
	generate reentrants      	= `reentrants'						// Number of re-entrants
	generate new_affiliates  	= `new_affiliates'					// Number of new affiliates
	generate exiters 		 	= `exiters'							// Number of exiters
	generate exits_target 	 	= (`turnover_target'/ 100) * affiliates / 2 // Target number of exists (assuming inflows match outflows)	
	generate reentrants_target 	= exits_target 						// Target number of re-entrants (assuming inflows match outflows)
	generate double transition_multiplier = 1							// Symmetric multiplicative anchor adjustment (1 = none, as in baseyear) - transition_in * mult, transition_out / mult
	generate expected_reentrants = .
	generate expected_exits 	= .
	generate transition_in 		= .
	generate transition_out 	= .
	generate log_cod 			= log(max(contribution_density, 0.001))


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
timer off 3
//	Affiliates: Loop over the projection period
	forvalues yr = `startyear'/`endyear' {

		// Save the last row of the dataset for later (when adding new ID numbers)
		local last_row = _N
		
		// Record the previous year
		local lastyear = `yr' - 1


		
		************************************************************************
		************************************************************************
		timer on 4
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
		timer off 4
		timer on 5
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
			local db_minpen_index_wage    = `db_minpen_index_wage_`yr_db_minpen''
			
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
		// Note (ANNUAL DATA): The parameters are assigned to EVERYONE with a reference wage, not only to those who worked
		// last year (dens > 0). Otherwise people who were not working in the base year (most older affiliates in the
		// synthetic data) have no minimum service requirement, fail the eligibility test, and cannot retire in the first
		// projection year - they then all become eligible in the second year (spike in retirements).
		forvalues b = `nb_er'(-1)1 {
			replace db_accrual_rate 	= `db_accrual_rate_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' * `db_thr_scale'
			replace db_standard_rate 	= `db_standard_rate_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' * `db_thr_scale'
			replace db_min_service_req 	= `db_min_service_req_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' * `db_thr_scale'
			replace db_accrual_max 		= `db_accrual_max_`b'_`yr_pol''		if reference_wage <= `db_thresh_`b'_`yr_pol'' * `db_thr_scale'
			replace db_early_penalty	= `db_early_penalty_`b'_`yr_pol''	if reference_wage <= `db_thresh_`b'_`yr_pol'' * `db_thr_scale'
			replace db_late_bonus 		= `db_late_bonus_`b'_`yr_pol''		if reference_wage <= `db_thresh_`b'_`yr_pol'' * `db_thr_scale'
			} // end forvalues b
			

		

		************************************************************************
		************************************************************************
		timer off 5
		timer on 6
		//	Stage 1 - Bring in the new affiliates
		//	Note: We start with the baseline observations and append the projected new affiliates
		display " "
		display "Adding new affiliates from `affiliates`yr''"
		local first_new = _N + 1					// First row of the new affiliates (they are appended at the end)
		append using `affiliates`yr''
		local last_new = _N

		// Give new affiliates a new id number
		local max_id = id[`last_row']
		replace new_affiliate = 0
		if `last_new' >= `first_new' {
		replace new_affiliate_flag = `yr' if missing(id) in `first_new'/`last_new'
		replace new_affiliate = 1		if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Flag for when someone becomes a new affiliate
		replace id = `max_id' + (_n - `last_row') if missing(id) in `first_new'/`last_new'


		***************
		// Clean up the value for new affiliates
		// Note (ANNUAL DATA): new affiliates get a single row, tagged year == `yr', with these
		// starting values; there is no month = 0 lag row for them since a new affiliate has no
		// "last year" to reference (Stage 5 below defaults their *_last values to 0/missing).
		replace yob = year - age 				if new_affiliate_flag == `yr' in `first_new'/`last_new'
		replace birthmonth = runiformint(1, 12) if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Unused in the annual model, kept for output-variable compatibility
		replace deathmonth = runiformint(1, 12) if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Unused in the annual model, kept for output-variable compatibility
		replace status = 1  	 				if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Everyone starts out alive
		replace wage_decile_ref = wage_decile  	if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Everyone is given a wage decile ot start
		// Note: As new affiliated are created before we move the data forward, that start with zero values (which are then incremented later on)
		replace los = 6 		 				if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Length of service (months) - assume 6 months to start
		replace loa = 6 						if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Length of affiliation (months) - assume 6 months to start
		replace spell_length = 6				if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Duration in job or unemployment (months) - assume 6 months to start
		replace dens = 6						if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Placeholder: this year's months worked, drawn in Stage 5
		replace contribution_density = 1		if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Initial density is 1 until it is updated
		replace log_cod = 0 					if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Initial LN(density) is 0 until it is updated
		replace age_grp = floor(age / 5) * 5	if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Ensure that age group is populated
		replace months = 12						if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Ensure that number of months is populated
		// Note: density_decile is assigned below (conditional on wage_decile_ref, via the
		// baseyear-derived CDF), not here - see the block after pension-type assignment.


		***************
		// Assign to a pension type
		replace start_year = floor(max(`yr' - (loa / 12), 0))	if new_affiliate_flag == `yr' in `first_new'/`last_new'
		// [TODO: Adjust this so that either the DC or the DB plan can be either first or second]
		replace pension_class = 2 				if new_affiliate_flag == `yr' & start_year >= `dc_year_start' in `first_new'/`last_new'		// Assign pension type to DC if valid year
		replace pension_class = 1 				if new_affiliate_flag == `yr' & start_year < `dc_year_start' in `first_new'/`last_new'		// Assign pension type to DB if valid year
		replace dc_pension_benefit = 0			if new_affiliate_flag == `yr' in `first_new'/`last_new'		// New affiliates start with no DC 
		replace iacc = 0	 					if new_affiliate_flag == `yr' in `first_new'/`last_new'		// Initial invidual account balance


		
		***************
		// Assign density_decile by sampling from P(density_decile | wage_decile_ref), the
		// baseyear-derived conditional CDF built earlier (cdf_w_d locals) - rather than a
		// pure uniform assignment, since density and wage are correlated in the real
		// population. Draw ONE runiform() per person (u_decile) and compare it against the
		// cumulative thresholds in increasing order, stopping at the first d whose
		// threshold it clears (via the missing() guard) - this correctly implements
		// inverse-CDF sampling.
		generate double u_decile = runiform() in `first_new'/`last_new'
		forvalues w = 1/10 {
			forvalues d = 1/10 {
				replace density_decile = `d' if missing(density_decile) & new_affiliate_flag == `yr' & wage_decile_ref == `w' & u_decile <= `cdf_`w'_`d'' in `first_new'/`last_new'
			} // end forvalues d
		} //  end forvalues w
		drop u_decile
		} // end if there are new affiliates

		



		
		************************************************************************
		************************************************************************
		timer off 6
		timer on 7
		//	Stage 2 - Project existing dataset forward
		// 	Project the last observation for each individual forward
		// 	Note: At this point we have new affiliates for the new year, but not yet the existing population
		//	Note (ANNUAL DATA): There is no monthly expansion any more, and no `month' variable -
		//	each affiliate has exactly one row per year, indexed by `year' alone. "Last year's
		//	value", which the monthly version read via the `l.' lag operator, is instead captured
		//	here as a snapshot (by id) of last year's row, joined onto this year's row as `*_last'
		//	variables for Stage 5 to use, then dropped once Stage 5 is done with them.

		//	Snapshot last year's ending values for continuing affiliates (new affiliates have no
		//	year == `lastyear' row - Stage 5 below fills in their defaults: no prior work, no prior wage)
		preserve
			keep if year == `lastyear'
			keep id dens los loa spell_length wage wage_decile
			rename (dens los loa spell_length wage wage_decile) ///
				   (dens_last los_last loa_last spell_last wage_last wage_decile_last)
			tempfile lastyear_snapshot
			save `lastyear_snapshot', replace
		restore

		//	Continuing affiliates: duplicate their (year == `lastyear') row forward into `yr'.
		//	The true original row (still tagged year == `lastyear') is left behind and is dropped
		//	below in Stage 3 by `keep if year == `yr'' - this also preserves the "previous year's
		//	wage" lookup at the start of Stage 3, which reads off that same leftover row.
		capture drop expanded
		expand 2 if year == `lastyear', generate(expanded)
		replace year = `yr' if expanded

		//	Join in last year's snapshot. New affiliates (no match in `lastyear_snapshot') default
		//	to zero prior service/tenure/months worked; wage_last/wage_decile_last stay missing,
		//	correctly signalling "no prior wage" (Stage 5 samples them a fresh wage).
		capture drop dens_last los_last loa_last spell_last wage_last wage_decile_last
		join dens_last los_last loa_last spell_last wage_last wage_decile_last, ///
			from(`lastyear_snapshot') by(id) keep(1 3) nogenerate
		replace dens_last  = 0 if missing(dens_last)  & year == `yr'
		replace los_last   = 0 if missing(los_last)   & year == `yr'
		replace loa_last   = 0 if missing(loa_last)   & year == `yr'
		replace spell_last = 0 if missing(spell_last) & year == `yr'


		// Update the labour market assumptions
		local turnover_target = `turnover_`yr''
		local emp_rate_target = `emp_rate_target_`yr''		// Direct employment-rate level target (1 = 100%) for this year



		************************************************************************
		************************************************************************
		timer off 7
		timer on 8
		//	Stage 3 - Compute the variables that we need and then drop the previous year
		//	Note: We do this for computational reasons (otherwise this takes way too long to run)

		// Grab the prvious year's wages
		// Note: We only calculate it like this for the start year. Otherwise we push forward the current average [see below]
		if `yr' == `startyear' {
			quietly summarize wage if year == `yr' - 1
			local old_wage = r(mean)
			} // if year == `startyear'

		// Keep only the current year (drops the leftover year == `lastyear' rows left behind by Stage 2)
		keep if year == `yr'
		
		
		// Update person's age
		// Note (ANNUAL DATA): everyone ages by one year at the start of the year, since there is
		// no monthly resolution any more. This must happen before age_gap/retirement_age/no_hope
		// below, since those (and the annual transition models in Stage 5) are covariates defined
		// on this year's age, matching how age is defined in the estimation data.
		replace age = age + 1 if status != 99	// Update age if person is not dead
		replace age_grp = floor(age / 5) * 5	// 5-year grouping


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

		// Pension pull: years until the person can retire = months until BOTH the earliest retirement age
		// and the minimum service are reached (los_gap is based on start-of-year service here)
		if `pension_pull' == 1 {
			replace years_to_elig = max(max(`db_retage_early_male'   - age, 0) * 12, los_gap) / 12 if gender == 1 & pension_class == 1
			replace years_to_elig = max(max(`db_retage_early_female' - age, 0) * 12, los_gap) / 12 if gender == 2 & pension_class == 1
			replace years_to_elig = max(max(`dc_retage_early_male'   - age, 0) * 12, los_gap) / 12 if gender == 1 & pension_class == 2
			replace years_to_elig = max(max(`dc_retage_early_female' - age, 0) * 12, los_gap) / 12 if gender == 2 & pension_class == 2

			// Bands (the models were estimated on people who cannot yet retire: eligible people take the nearest band, "up to 1 year")
			replace yte_band = 6
			replace yte_band = 5 if years_to_elig <= 10
			replace yte_band = 4 if years_to_elig <= 5
			replace yte_band = 3 if years_to_elig <= 3
			replace yte_band = 2 if years_to_elig <= 2
			replace yte_band = 1 if years_to_elig <= 1
			replace yte_band = 6 if missing(years_to_elig)

			// Bands of the service still needed (los_gap is in months)
			replace sg_band = 0
			replace sg_band = 1 if los_gap >   0 & los_gap <= 12
			replace sg_band = 2 if los_gap >  12 & los_gap <= 24
			replace sg_band = 3 if los_gap >  24 & los_gap <= 36
			replace sg_band = 4 if los_gap >  36 & los_gap <= 60
			replace sg_band = 5 if los_gap >  60 & !missing(los_gap)

			// Smooth (piecewise-linear) terms - the same definitions as in the estimation
			// ("04 - Pre-processing - Estimate transitions rates - ANNUAL DATA VERY LOW PULL.do")
			// People who can already retire have years_to_elig = 0, the nearest value with data
			replace yte_p1 = min(min(years_to_elig, 15), 1)
			replace yte_p2 = min(max(min(years_to_elig, 15) - 1, 0), 2)
			replace yte_p3 = min(max(min(years_to_elig, 15) - 3, 0), 2)
			replace yte_p4 = min(max(min(years_to_elig, 15) - 5, 0), 5)
			replace yte_p5 = max(min(years_to_elig, 15) - 10, 0)
			replace sg_years = min(los_gap / 12, 5)
			// Missing distance (should not happen): treat as far from eligibility
			replace yte_p1 = 1 if missing(years_to_elig)
			replace yte_p2 = 2 if missing(years_to_elig)
			replace yte_p3 = 2 if missing(years_to_elig)
			replace yte_p4 = 5 if missing(years_to_elig)
			replace yte_p5 = 5 if missing(years_to_elig)
			replace sg_years = 5 if missing(sg_years)
		}

		
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
		timer off 8
		timer on 9
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
		// Note (ANNUAL DATA): applied directly as a single annual draw (no deathmonth timing needed,
		// since there is no monthly resolution). Housekeeping (deathyear, wage_at_death, zeroing
		// dens/benefits for the newly dead) is handled just below in Stage 6, unchanged.
		replace status = 99 if mortality > runiform()


		
		************************************************************************
		************************************************************************
		timer off 9
		timer on 10
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
		//	Predict this year's months worked from the transition_in/transition_out
		//	hazard-rate models, then simulate a 12-step employment-status Markov
		//	chain in-memory (still one row per person-year - see file header note).
		//	Simulating month-to-month transitions makes staying in your current state
		//	the norm (transition_out/transition_in are typically well under 50%), so
		//	employment spells naturally clump instead of eroding toward the pooled mean
		//	over a long horizon.
		//	Separate capture-drop per variable, not one combined list: Stata's `drop
		//	varlist' fails ENTIRELY if ANY one listed variable doesn't exist yet (true
		//	on the very first Stage 5 call, when predict_xb_exit/predict_xb_entry have
		//	never been generated) - even wrapped in `capture', that silently no-ops the
		//	WHOLE command, including for transition_out/transition_in, which already
		//	exist (pre-declared before the loop) and then collide with the `generate'
		//	below. Same bug class as the earlier predict_xb stranded-variable issue.
		capture drop predict_xb_exit
		capture drop predict_xb_entry
		capture drop transition_out
		capture drop transition_in
		capture drop log_spell_length
		// log1p of spell_length: the estimation models use log_spell_length, not
		// spell_length, in both hazard equations - see "04 - Pre-processing - Estimate
		// transitions rates - ANNUAL DATA VERY LOW.do" for why. +1 avoids log(0)=missing
		// for the common spell_length==0 case (a brand-new spell).
		generate double log_spell_length = log(spell_length + 1)
		estimates restore job_exit_stored
		predict predict_xb_exit, xb
		generate transition_out = 1 - exp(-exp(predict_xb_exit))
		replace  transition_out = min(max(transition_out, 0.0001), 0.9999) // Add guardrails

		estimates restore job_entry_stored
		predict predict_xb_entry, xb
		generate transition_in = 1 - exp(-exp(predict_xb_entry))
		replace  transition_in = min(max(transition_in, 0.0001), 0.9999) // Add guardrails

		**********
		// Starting state (entering this year): existing affiliates start from an empirical
		// proxy for "were they working in the last observed month of last year" (dens_last /
		// 12); new affiliates (no last-year row) start from this year's own (pre-anchor)
		// steady-state probability, the natural no-information prior. Computed here, before the
		// anchor, because the anchor needs a population-level "current employment rate"
		// snapshot and the 12-step Markov simulation further below needs these same per-person
		// starting probabilities - one definition, used both places.
		generate double p_steadystate = transition_in / (transition_in + transition_out)
		generate double p_start = dens_last / 12
		replace p_start = p_steadystate if new_affiliate_flag == `yr'
		replace p_start = min(max(p_start, 0), 1)

		**********
		// Anchor: closes delta_employment using the EXACT closed-form solution of the 2-state
		// employment-status Markov chain run for 12 months with constant hazards.
		//
		// For a person with CONSTANT monthly hazards transition_in=p, transition_out=q over the
		// year (hazards are only re-estimated once per year - see note on spell_length further
		// up), starting from employment probability p_start, the EXACT probability of being
		// employed at month 12 is:
		//     P_year_end = p_ss + (p_start - p_ss) * r^12
		// where p_ss = p/(p+q) (the steady state) and r = 1-p-q (the persistence eigenvalue of
		// the 2-state chain). This is the same quantity the 12-step Markov simulation below
		// actually produces in expectation, so targeting it directly accounts for within-year
		// leakage automatically.
		//
		// SYMMETRIC MULTIPLICATIVE adjustment: a single shared multiplier is applied to BOTH
		// hazards at once - transition_in is scaled UP by the multiplier while transition_out is
		// scaled DOWN by the same multiplier (divided by it), rather than treating one hazard as
		// a primary lever and the other as a last resort. One parameter, found by bisecting over
		// log(multiplier) (not the raw multiplier, so that halving and doubling the hazards are
		// symmetric steps in the search). mult==1 leaves both hazards at their raw, unadjusted
		// levels; mult>1 raises employment (more entries, fewer exits), mult<1 lowers it.
		noisily display " "
		noisily display "Adjusting transition rates to match labour market path..."

		quietly count if status != 99
		local affiliates_now = r(N)

		quietly summarize p_start
		local current_emp_rate = r(mean)

		local target_emp_rate = min(max(`emp_rate_target', 0.0001), 0.9999) // Add guardrails

		// Bisect over log(multiplier): avg_share is monotonically INCREASING in the multiplier,
		// since raising transition_in and lowering transition_out both push employment up
		// together (no direction-dependent branching needed). 30 iterations over a log-range of
		// 20 gives precision of 20/2^30 =~ 2e-8, more than enough given the final hazards are
		// floored/capped at 0.0001-0.9999 regardless.
			mata: anchor_search("p_start", "transition_in", "transition_out", `target_emp_rate')
			replace transition_multiplier = exp(scalar(anchor_logmult))

		replace transition_in  = min(max(transition_in  * transition_multiplier, 0.0001), 0.9999)
		replace transition_out = min(max(transition_out / transition_multiplier, 0.0001), 0.9999)

		**********
		// Simulate employment status month-by-month for 12 months, using this year's (fixed,
		// now-anchored) hazard rates - spell_length (and hence transition_in/transition_out) is
		// only updated once per YEAR, matching how it's defined in the estimation data, so the
		// hazards don't change within a year, but the simulated employment STATE still evolves
		// stochastically month to month, which is what produces realistic within-year persistence.
		generate byte employed_state = (runiform() < p_start)
		generate byte months_worked_sim = 0
		// Generate the state_start tempvar ONCE and just replace it each month, instead of
		// generate+drop on every iteration - same snapshot semantics, far fewer
		// variable-table operations per year.
		tempvar state_start
		quietly generate byte `state_start' = .
		forvalues m = 1/12 {
			quietly replace months_worked_sim = months_worked_sim + employed_state
			// Snapshot the state entering this month, and have BOTH checks reference that
			// snapshot rather than `employed_state' directly - otherwise someone who exits on
			// the first replace becomes eligible for the second (entry) replace within the SAME
			// month, since both lines would otherwise read the just-updated employed_state,
			// making employed people stickier than the 2-state Markov chain is meant to simulate.
			quietly replace `state_start' = employed_state
			quietly replace employed_state = 0 if `state_start' == 1 & runiform() < transition_out
			quietly replace employed_state = 1 if `state_start' == 0 & runiform() < transition_in
		}
		quietly drop `state_start'

		replace dens = months_worked_sim				// Update this year's months worked

		**********
		// New affiliates cannot show dens==0 in their first year: becoming an affiliate happens
		// BECAUSE they took a job, so by construction they have between 1 and 12 months of
		// contributions that year. Rather than a flat floor or a hand-built decile-specific rule,
		// redraw the SAME 12-step simulation (this person's own p_start, transition_in,
		// transition_out) for anyone whose first draw came out to dens==0, repeating until
		// dens>=1. This is equivalent to drawing from the distribution conditional on dens>=1
		// using the person's own hazards, so it stays wage-decile/density-decile-aware for free.
		// Only ever touches new affiliates still at dens==0 this year - continuing affiliates
		// with a genuine dens==0 year are left alone (they are not at contribution_density==0
		// overall, since their los_last>0 already). Bounded retry count with a floor-of-1
		// fallback guards against the extremely rare case of never clearing dens>=1 within the
		// attempt budget.
		local max_retries = 20
		// The redraw only concerns the few new affiliates that came out with dens == 0: copy them to a small frame,
		// repeat the 12-step simulation there until dens >= 1 (as before, at most max_retries attempts, then a floor of 1),
		// and copy the result back. Looping over the whole dataset for every attempt was the most expensive part of the model.
		quietly count if new_affiliate_flag == `yr' & dens == 0
		if r(N) > 0 {
			capture frame drop redraw
			quietly generate long _rid_redraw = _n
			frame put _rid_redraw p_start transition_in transition_out dens if new_affiliate_flag == `yr' & dens == 0, into(redraw)
			frame redraw {
				quietly generate byte employed_state = .
				quietly generate byte months_worked_sim = 0
				quietly generate byte state_start = .
				forvalues attempt = 1/`max_retries' {
					quietly count if dens == 0
					if r(N) == 0 {
						continue, break
					}
					quietly replace employed_state    = (runiform() < p_start) if dens == 0
					quietly replace months_worked_sim = 0                      if dens == 0
					forvalues m = 1/12 {
						quietly replace months_worked_sim = months_worked_sim + employed_state if dens == 0
						quietly replace state_start = employed_state if dens == 0
						quietly replace employed_state = 0 if state_start == 1 & runiform() < transition_out & dens == 0
						quietly replace employed_state = 1 if state_start == 0 & runiform() < transition_in  & dens == 0
					}
					quietly replace dens = months_worked_sim if dens == 0
				}
				quietly replace dens = 1 if dens == 0		// Backstop (should be rare/never hit)
				keep _rid_redraw dens
			}
			quietly frlink 1:1 _rid_redraw, frame(redraw) generate(_lnk_redraw)
			quietly frget dens_redraw = dens, from(_lnk_redraw)
			quietly replace dens = dens_redraw if !missing(dens_redraw)
			drop _rid_redraw _lnk_redraw dens_redraw
			frame drop redraw
		}

		// The anchor targets the AVERAGE SHARE OF THE YEAR WORKED, not a year-end snapshot - so
		// the validation check below uses mean(dens)/12, the same quantity the bisection's
		// avg_share formula is built to predict, and the same quantity that directly determines
		// contribution_density.
		quietly summarize dens
		local achieved_avg_share = r(mean) / 12
		noisily display "Year-average employment rate: target=" %4.1f 100*`target_emp_rate' "%  achieved=" %4.1f 100*`achieved_avg_share' "%"

		drop predict_xb_exit predict_xb_entry log_spell_length p_steadystate p_start employed_state months_worked_sim


		*******************
		// Determine exit/reentry events, relative to last year's status - used for reporting
		// and for the wage-decile/spell_length updates below
		noisily display " "
		noisily display "Assigning wages to labour market entrants..."
		replace exiter    = (dens_last > 0 & dens == 0)
		replace reentrant = (dens_last == 0 & dens > 0)


		*******************
		// Update wage decile: 0 if not working at all this year; the person's reference decile
		// on reentry; otherwise carried forward from last year
		replace wage_decile = 0               if dens == 0
		replace wage_decile = wage_decile_ref if dens > 0 & reentrant == 1
		replace wage_decile = wage_decile_last if dens > 0 & reentrant == 0

		*******************
		// Update length of service (los, accrues by months actually worked), length of
		// affiliation (loa, accrues a full year regardless of work status), and contribution density
		replace los = los_last + dens	// Increment service by however many months were worked this year
		replace loa = loa_last + 12	// A full year of affiliation always elapses
		replace contribution_density = los / loa
		replace log_cod = log(max(contribution_density, 0.001))

		// Update los-gap and pension-gap calculations
		replace los_gap = max(12 * `db_min_service_req' - los, 0) if pension_class == 1 // DB pension plan
		replace los_gap = max(12 * `dc_min_service_req' - los, 0) if pension_class == 2 // DC pension plan
		replace pension_gap = max(age_gap, los_gap)

		*******************
		// Update spell_length: mirrors the "new spell" rule used to build this covariate in
		// "04 - Pre-processing - Estimate transitions rates - ANNUAL DATA.do" - a partial year
		// (1-11 months) signals a mid-year transition and starts a new spell; so does
		// dens==loa (a brand-new affiliate's first, fully-worked year). A full year or a fully
		// idle year (for an existing spell) continues the current spell instead.
		//
		// A fresh spell starts at exactly 0, not at this year's dens, since the estimation
		// file's spell_length is LAGGED (excludes the current row's own dens). Continuing
		// spells use spell_last (the value carried into this year) plus this year's
		// now-realized dens, rather than the current spell_length variable, to avoid relying
		// on it not having been touched earlier in Stage 5.
		generate byte new_spell = (dens > 0 & dens < 12) | (dens == loa)
		replace spell_length = 0                   if new_spell
		replace spell_length = spell_last + dens   if !new_spell
		drop new_spell


		*******************
		// Assign wages
		// Exiters: capture their wage as wage_ref before losing it; no wage while not working
		replace wage_ref = wage_last if exiter == 1
		replace wage     = .         if dens == 0

		// Continuing workers: carry forward last year's wage (wage growth is applied below, annually)
		replace wage = wage_last if dens > 0 & reentrant == 0 & !missing(wage_last)

		// Reentrants: resume at the wage they left with, if known
		// Note: We give reentrants the same wage they left with so that we can assign wage penalties (in a later revision)
		replace wage = wage_ref if dens > 0 & reentrant == 1 & !missing(wage_ref)

		// New affiliates and reentrants/entrants with no wage history: sample a wage from the decile distribution
		// Note: bounded by the min and max of the decile
		replace wage = max(min(rnormal(wage_mean_decile, wage_sd_decile), wage_max_decile), wage_min_decile) if dens > 0 & missing(wage)

		*******************
		// Update the reference wage for re-entrants who didn't have a wage in the past
		tempvar wage_ref_update
		gegen `wage_ref_update' = max(wage_ref), by(id)
		replace wage_ref = `wage_ref_update' if missing(wage_ref)

		*******************
		// Drop the last year's-value reference columns joined in during Stage 2 - no longer needed
		drop dens_last los_last loa_last spell_last wage_last wage_decile_last
			
			

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
		predict relative_wage_growth if dens > 0, xb
		
		// Beyond the age range the model was estimated on, we have no evidence
		// for an age-specific growth differential. Topcoding age_m prevents the
		// cubic from being evaluated out of range, but it would otherwise still
		// apply whatever differential was fitted at the boundary indefinitely to
		// anyone who remains employed past that age. 
		replace relative_wage_growth = 100 if age > `max_reliable_age' & !missing(relative_wage_growth)


		// Adjust global wage growth to reflect age-sex-decile profiles
		replace sim_wage_growth = wage_growth * relative_wage_growth / 100
	
		// Adjust wages
		replace wage     = wage     * (1 + (sim_wage_growth / 100))  if dens > 0

		**********
		// Re-adjust wages to ensure that user-defined wage growth is obtained
		// Get the average wage of the sample (this year)
		quietly summarize wage
		local new_wage = r(mean)
		replace average_wage = `new_wage'

		// Compare to average wage of last year (defined earlier in the code)
		local wage_growth_obs = (`new_wage' / `old_wage') - 1

		// Compute aggregate adjustments
		local wage_adjustment = (1 + `wage_growth_user') / (1 + `wage_growth_obs')

		// Adjust wages to reflect user-defined aggregate wage growth
		// Note: For those not working, reference wages are grown by the economy-wide average
		replace wage     = wage     * `wage_adjustment'
		replace wage_ref = wage_ref * (1 + `wage_growth_user')
		
		// Save the new wage as the old wage [we will use it for next year's wage adjustments]
		local old_wage = `new_wage'
		
	
		


	

		
		************************************************************************
		************************************************************************
		timer off 10
		timer on 11
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
		timer off 11
		timer on 12
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
		timer off 12
		timer on 13
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
		// Note (ANNUAL DATA): there is exactly one row per id at this point (Stage 3 already
		// dropped last year's leftover row), so this is just that row's own wage.
		capture drop  avg_wage_ind
		gegen  avg_wage_ind = mean(wage), by(id)

		// Determine covered wages
		replace db_covered_wage = max(min(wage, `db_covered_wage_max'), `db_covered_wage_min') if dens > 0
		replace dc_covered_wage = max(min(wage, `dc_covered_wage_max'), `dc_covered_wage_min') if dens > 0

		// Compute average covered wage across the year
		capture drop avg_db_covered_wage
		gegen avg_db_covered_wage = mean(db_covered_wage), by(id)

		// Compute average covered wage across the year
		capture drop avg_dc_covered_wage
		gegen avg_dc_covered_wage = mean(dc_covered_wage), by(id)
		// db_covered_wage/dc_covered_wage are only set (just above) for dens > 0; for a worker
		// inactive this year they still carry forward last year's value (from Stage 2's row
		// duplication), which would incorrectly drive the reference-wage EWMA (Step 2 below).
		// Null out the averages for anyone inactive this year so Step 2 is skipped for them.
		replace avg_dc_covered_wage = . if dens == 0
		replace avg_db_covered_wage = . if dens == 0
		
		

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
		// Note (ANNUAL DATA): `samp'/`affiliates' count ROWS (one per person this year, not 12),
		// so they no longer need dividing by 12; `emp' sums dens, which is now months worked
		// (0-12) rather than a monthly 0/1 flag, so dividing that by 12 still gives the correct
		// average-employed-headcount.
		gegen `samp' 	  		= count(dens)  		  	//, by(wage_decile_ref)	// Population count
		gegen `emp'  	  		= sum(dens)    		   	//, by(wage_decile_ref) 	// Employment count
		gegen `reentrants'  	= sum(reentrant)      	//, by(wage_decile_ref)	// Number of re-entrants
		gegen `affiliates'		= sum(status!=99)		//, by(wage_decile_ref)	// Number of total affiliates
		gegen `new_affiliates'  = sum(new_affiliate)  	//, by(wage_decile_ref)	// Number of new affiliates
		gegen `exiters'  		= sum(exiter)  		  	//, by(wage_decile_ref)	// Number of exiters


		// This is mostly for reporting (and for adjusting transition rates)
		replace sample_pop 	 	= `samp' 							// Annual Population count
		replace affiliates 	 	= `affiliates' 						// Number of total affiliates
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
		timer off 13
		timer on 14
		//	Stage 9 -  Update DC individual account balance (iacc)
		//	Done annually (once per year, after this year's transition is resolved).

		// Count months actively contributing this year
		// Note (ANNUAL DATA): dens IS this year's months contributed, and there is only one row
		// per id/year, so this now just copies dens onto that row (kept in this form since
		// Stage 11 downstream still references `months_contributed_yr').
		capture drop months_contributed_yr
		gegen months_contributed_yr = sum(dens), by(id year)


		// Covered wage: cap at the insurable ceiling
		replace dc_covered_wage = max(min(wage, `dc_covered_wage_max'), `dc_covered_wage_min') if dens > 0

		**********
		// 	Employer pension contribution rates by income bracket and year
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		// Brackets after the last year of their tables: move with wage growth (index_thresholds)
		if `index_thresholds' == 1 {
			if `yr' > `dc_employer_max_year' local dc_thr_scale_er  = `dc_thr_scale_er'  * (1 + `wage_growth_user')
			if `yr' > `dc_employee_max_year' local dc_thr_scale_ee  = `dc_thr_scale_ee'  * (1 + `wage_growth_user')
			if `yr' > `dc_gov_max_year'      local dc_thr_scale_gov = `dc_thr_scale_gov' * (1 + `wage_growth_user')
		}
		local yr_er   = min(`yr', `dc_employer_max_year')
		local nb_er   = `dc_employer_nbrackets_`yr_er''
		replace employer_ssc_rate = 0
		forvalues b = `nb_er'(-1)1 {
			replace employer_ssc_rate = `dc_employer_rate_`b'_`yr_er'' / 100 if wage <= `dc_employer_thresh_`b'_`yr_er'' * `dc_thr_scale_er' & dens > 0
			} // end forvalues b
		replace employer_ssc_rate = employer_ssc_rate + (`dc_ssc_er' / 100)  if dens > 0 // Add in the flat rate employer ssc

		// Compute employer contributions
		// Note (ANNUAL DATA): this is now the FULL YEAR's contribution (rate x wage x months
		// worked), since each row represents the whole year rather than a single month.
		replace dc_employer_ssc = 0
		replace dc_employer_ssc = dc_covered_wage * employer_ssc_rate * months_contributed_yr if dens > 0



		**********
		//  Government social security subsidies (if any)
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		// [TODO: This works for the flat rate of mexico, need to generalize to proportional subsidies in other countries]
		local yr_gov    = min(`yr', `dc_gov_max_year')	// Latest year of policy parameters
		local nb_gov    = `dc_gov_nbrackets_`yr_gov''	// Number of brackets
		replace gov_subsidy = 0
		// Loop backwards through the brackets to get the contribution amount
		// Note: gov_subsidy is already annualized (x months_contributed_yr) here
		forvalues b = `nb_gov'(-1)1 {
			replace gov_subsidy = months_contributed_yr * `dc_gov_subsidy_`b'_`yr_gov'' * `dc_thr_scale_gov' if wage <= `dc_gov_thresh_`b'_`yr_gov'' * `dc_thr_scale_gov' & dens > 0
			} // end forvalues b

		// Compute government contributions
		replace government_ssc_rate = 0
		replace government_ssc_rate = `dc_ssc_gov' / 100 if dens > 0
		replace dc_government_ssc = 0
		// Note (ANNUAL DATA): gov_subsidy is already an annual total (see above); only the
		// wage-proportional term needs multiplying by months_contributed_yr here.
		replace dc_government_ssc = gov_subsidy + (dc_covered_wage * government_ssc_rate * months_contributed_yr) if dens > 0




		*********
		//  Employee pension contribution rates by income bracket and year
		//	Iterate brackets from HIGHEST to LOWEST threshold so the final assignment
		//	is the lowest applicable bracket (highest threshold that worker's wage exceeds).
		local yr_ee   = min(`yr', `dc_employee_max_year')
		local nb_ee   = `dc_employee_nbrackets_`yr_ee''
		replace employee_ssc_rate = 0
		forvalues b = `nb_ee'(-1)1 {
			replace employee_ssc_rate = `dc_employee_rate_`b'_`yr_ee'' / 100 if wage <= `dc_employee_thresh_`b'_`yr_ee'' * `dc_thr_scale_ee' & dens > 0
			} // end forvalues b
		replace employee_ssc_rate = employee_ssc_rate + (`dc_ssc_ee' / 100) if dens > 0 // Add in the flat rate employer ssc

		// Compute employee contributions (full year, see employer note above)
		replace dc_employee_ssc = 0
		replace dc_employee_ssc = dc_covered_wage * employee_ssc_rate * months_contributed_yr if dens > 0

		
		
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
		// The account is in nominal units: if the return is real, convert it with the inflation of the year
		if `dc_return_is_real' == 1 local dc_net_return = (1 + `dc_net_return') * (1 + `pindex_inflation' / 100) - 1
		*local dc_net_return_month 	= (1 + `dc_net_return')^(1/12)	// Monthly return on account
		

		
		*********
		// Total annual DC contribution (employer, employee, and government subisdies [and possibly self-employed])
		replace dc_total_contrib = dc_employer_ssc + dc_employee_ssc + dc_government_ssc
		capture drop dc_contributions
		bysort id (year): generate dc_contributions = sum(dc_total_contrib)

		// Credit contributions and apply net investment return to iacc
		// Note: We accumulate contributions but only apply the annual growth at the end of the year.
		//		 This is an approximation that saves some compute time (by keeping the calculations out of the monthly loop).
		//   iacc(t) = [iacc(t-1) + dc_contrib(t)] x (1+r)
		*replace iacc = (iacc + dc_total_contrib)  * (1 + `dc_net_return') if status != 99 // If not dead
		replace iacc = (iacc + dc_contributions)  * (1 + `dc_net_return') if status != 99 // If not dead
		
		
		***************
		// Compute the Value of the Annuity
		// [TODO: Confirm if we need to adjust this based on if the pension is indexed or not, I think we do]
		
		// The account (iacc) is in nominal units, so the annuity is priced in nominal terms.
		// dc_annuity_rate is a REAL discount rate: convert it to a nominal rate with the assumed inflation of the year.
		// If the pension is not indexed (dc_annuity_indexed == 0) it is a level nominal annuity (growth 0).
		// If it is indexed, the payment grows at the pension indexation rate (CPI-only when alpha2 = alpha3 = 0).
		local dc_nominal_rate = (1 + `dc_annuity_rate') * (1 + `pindex_inflation' / 100) - 1
		local dc_pension_growth = 0
		if `dc_annuity_indexed' == 1 {
			local dc_pension_growth = (`alpha1' * `pindex_inflation' + `alpha2' * `pindex_realwage' + `alpha3' * `pindex_anchor') / 100
		}
		local dc_af_spread = max(`dc_nominal_rate' - `dc_pension_growth', 0.001)
		
		// Present-value annuity factor (growing annuity; reduces to the level annuity when growth = 0)
		replace dc_annuity_factor = (1 - ((1 + `dc_pension_growth') / (1 + `dc_nominal_rate'))^(life_expectancy)) / `dc_af_spread'
	
		// Present-value annuity factor for the next year (approximate: subtract 1)
		replace dc_annuity_factor_next = (1 - ((1 + `dc_pension_growth') / (1 + `dc_nominal_rate'))^(life_expectancy - 1)) / `dc_af_spread'
		
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
		timer off 14
		timer on 15
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
		// Basic rate of the wage group + annual increment (db_late_bonus) x years of service beyond the minimum service requirement
		replace db_replacement_rate = db_standard_rate + db_late_bonus * max(yos - db_min_service_req, 0)
		replace db_replacement_rate = min(db_replacement_rate, db_accrual_max)						// Apply maximum
		// Retirement before the normal age: the pension is a share of the pension at the normal age (early_penalty = share lost per year)
		replace db_replacement_rate = db_replacement_rate * max(1 - db_years_early * db_early_penalty, 0)
		replace db_replacement_rate = max(db_replacement_rate, 0)									// No credit for retiring after the normal age

		

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
		replace db_replacement_rate_next = db_standard_rate + db_late_bonus * max(yos_next - db_min_service_req, 0)
		replace db_replacement_rate_next = min(db_replacement_rate_next, db_accrual_max)
		replace db_replacement_rate_next = db_replacement_rate_next * max(1 - db_years_early_next * db_early_penalty, 0)
		replace db_replacement_rate_next = max(db_replacement_rate_next, 0)
		
		
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
		// Minimum pension of NEW retirees: grows with the minimum-pension index, or with nominal wage growth if it is tied to a wage unit
		// (while the sheet has a row for the year, the value is reloaded from the sheet at the start of the next year)
		local db_minpen_base    	= `db_minpen_base'    	* (1 + cond(`db_minpen_index_wage' == 1, `wage_growth_user', `mpi_rate'))
		local db_minpen_refwage 	= `db_minpen_refwage' 	* (1 + `mpi_rate')
		local db_minpen_wage		= `db_minpen_adj1' 		* `db_minpen_refwage'	
		local db_minpen_wage_max	= `db_minpen_adj2' 		* `db_minpen_refwage'	 
		local db_pension_max     	= `db_pension_max' 		* (1 + `mpi_rate')
		local db_covered_wage_max 	= `db_covered_wage_max' * (1 + `mpi_rate')
		local db_covered_wage_min 	= `db_covered_wage_min' * (1 + `mpi_rate')
		// Wage groups of the DB formula (used with the reference wage of the next year): move with wage growth after the last table year
		if `index_thresholds' == 1 & `yr' >= `db_policy_max_year' local db_thr_scale = `db_thr_scale' * (1 + `wage_growth_user')
	
		
		
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
		timer off 15
		timer on 16
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

		// Retirement model option: affiliates (DB and DC) who are eligible retire with the model's annual probability,
		// instead of by the implicit-tax rule. Note: the model was estimated on DB retirees
		if `retirement_rule' == 2 {

			// The model uses the variables age, gender, age_at_earliest, age_at_normal and a binomial denominator `eligible'
			// Clamp age to the range the model was estimated on (restored afterwards) and protect any existing `eligible' variable
			capture confirm variable eligible
			local had_eligible = (_rc == 0)
			if `had_eligible' rename eligible eligible_saved
			generate double eligible = 1
			generate double age_saved = age
			replace age = min(max(age, `retmodel_min_age'), `retmodel_max_age')
			generate byte age_at_earliest = (age_saved == `db_retage_early_male')   if gender == 1 & pension_class == 1
			replace  age_at_earliest      = (age_saved == `db_retage_early_female') if gender == 2 & pension_class == 1
			replace  age_at_earliest      = (age_saved == `dc_retage_early_male')   if gender == 1 & pension_class == 2
			replace  age_at_earliest      = (age_saved == `dc_retage_early_female') if gender == 2 & pension_class == 2
			generate byte age_at_normal   = (age_saved >= `db_retage_male')   if gender == 1 & pension_class == 1
			replace  age_at_normal        = (age_saved >= `db_retage_female') if gender == 2 & pension_class == 1
			replace  age_at_normal        = (age_saved >= `dc_retage_male')   if gender == 1 & pension_class == 2
			replace  age_at_normal        = (age_saved >= `dc_retage_female') if gender == 2 & pension_class == 2

			// Predicted annual probability of retiring (cloglog link)
			estimates restore retirement_stored
			tempvar xb_retire
			predict double `xb_retire', xb
			replace retire_prob = 1 - exp(-exp(`xb_retire')) if inlist(pension_class, 1, 2)

			// Put the variables back as they were
			replace age = age_saved
			drop age_saved eligible age_at_earliest age_at_normal
			if `had_eligible' rename eligible_saved eligible

			// Eligible affiliates (same conditions as the original rule) retire with probability retire_prob
			replace retire_on_tax = ( runiform() < retire_prob & !missing(retire_prob) & retirement_age == 1 & status == 1 & pension_elig == 1 ) if inlist(pension_class, 1, 2)
		}

		// Apply the retirmeent rule (if not dead)
		// Retirement anchor: the number of new retirees is a share of the retirement-eligible affiliates.
		// The rule above decides WHO (propensity = model probability under rule 2, equal under rule 1)
		if `retirement_anchor' == 1 {
			tempvar elig_anchor prop_anchor key_anchor
			generate byte `elig_anchor' = (pension_elig == 1 & retirement_age == 1 & status == 1 & age < `too_old_to_retire')
			quietly summarize weight if `elig_anchor' == 1, meanonly
			if r(N) > 0 {
				generate double `prop_anchor' = 1
				if `retirement_rule' == 2 replace `prop_anchor' = max(retire_prob, 0.0001) if !missing(retire_prob)
				// Weighted draw without replacement: the lowest values of -ln(u) / propensity retire first
				generate double `key_anchor' = -ln(runiform()) / `prop_anchor' if `elig_anchor' == 1
				local pct_anchor = 100 * min(`retirement_share', 1)
				replace retire_on_tax = 0 if `elig_anchor' != 1
				if `pct_anchor' >= 100 {
					replace retire_on_tax = 1 if `elig_anchor' == 1
				}
				else if `pct_anchor' > 0 {
					quietly _pctile `key_anchor' [aweight = weight] if `elig_anchor' == 1, percentiles(`pct_anchor')
					replace retire_on_tax = (`key_anchor' <= r(r1)) if `elig_anchor' == 1
				}
				else replace retire_on_tax = 0 if `elig_anchor' == 1

				// Report: eligible affiliates, retirees and the share (weighted)
				quietly summarize weight if `elig_anchor' == 1, meanonly
				local anchor_elig = r(sum)
				quietly summarize weight if `elig_anchor' == 1 & retire_on_tax == 1, meanonly
				noisily display as text "Retirement anchor `yr': eligible affiliates = " %12.0fc `anchor_elig' " | new retirees = " %12.0fc r(sum) " | share = " %6.4f r(sum) / `anchor_elig' " | target share = " %6.4f `retirement_share'
			}
			drop `elig_anchor' `prop_anchor'
			capture drop `key_anchor'
		}

		replace status = 2 if retire_on_tax == 1 & status != 99

		// People who are too old to retire, then take pseudo retirement (and maybe get a lumpsum)
		replace status = 2 if age >= `too_old_to_retire' & status != 99	// (people who died this year stay dead)
		
		// People who have no hope of retiring by the too-old-age retire now as well
		replace status = 2 if los_gap > ((`too_old_to_retire' - age) * 12) & status != 99
		
		
		
		
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
		// Option right: DB-class retirees (transition generation) take the higher of the DB and the DC pension.
		// The DC pension is the account annuity within the DC minimum and maximum, if the DC conditions are met.
		// Those who prefer the DC pension are moved to pension_class = 2 (DB benefit set to zero) and the switch is recorded.
		if `option_right' == 1 {
			tempvar opt_ok opt_dc
			generate byte `opt_ok' = (status == 2 & pension_class == 1 & dc_pension_elig_mincont == 1 & (dc_pension_elig_age == 1 | dc_pension_elig_early == 1))
			generate double `opt_dc' = max(min(dc_annuity, dc_pension_maxpen), dc_pension_minpen) if `opt_ok' == 1
			replace pension_class_switch = (`opt_ok' == 1 & `opt_dc' > db_pension_benefit & !missing(`opt_dc')) if status == 2 & pension_class == 1
			quietly summarize weight if status == 2 & `opt_ok' == 1, meanonly
			local opt_n_ok = r(sum)
			quietly summarize weight if pension_class_switch == 1 & status == 2 & pension_class == 1, meanonly
			noisily display as text "Option right `yr': DB-class retirees able to choose = " %10.0fc `opt_n_ok' " | choose DC = " %10.0fc r(sum)
			replace dc_pension_benefit = `opt_dc'       if pension_class_switch == 1 & status == 2 & pension_class == 1
			replace dc_gov_pension     = max(dc_pension_minpen - dc_annuity, 0) if pension_class_switch == 1 & status == 2 & pension_class == 1
			replace minimum_pension    = (dc_gov_pension > 0) if pension_class_switch == 1 & status == 2 & pension_class == 1
			replace dc_pension_elig    = 1              if pension_class_switch == 1 & status == 2 & pension_class == 1
			replace db_pension_benefit = 0              if pension_class_switch == 1 & status == 2 & pension_class == 1
			replace db_gov_pension     = 0              if pension_class_switch == 1 & status == 2 & pension_class == 1
			replace db_pension_elig    = 0              if pension_class_switch == 1 & status == 2 & pension_class == 1
			replace pension_class      = 2              if pension_class_switch == 1 & status == 2 & pension_class == 1
			drop `opt_ok' `opt_dc'
		}

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
		timer off 16
		timer on 17
		//	Stage 13 - In-year reporting
		// 	Because each year's dataset is dropped once we move to the next, reporting is
		//	collected as we go: the finest-grain breakdown (age x gender x wage_decile x
		//	dens) is computed once, and the 15 coarser breakdowns + the grand total are
		//	derived from it (see CUBE TRICK below) instead of re-scanning the full
		//	person-level dataset 16 times. Each year's results are saved to their own
		//	tempfiles and only combined into `inyear_affiliate_reporting_tot'/
		//	`inyear_affiliate_reporting' once, after the main loop ends - instead of
		//	re-reading/appending/re-saving the whole growing reporting file every year.

		// Generate status totals
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

		generate retired     		= weight * (status == 2)
		generate disabled    		= weight * (status == 3)
		generate widowed     		= weight * (status == 4)
		generate deceased    		= weight * (status == 99)
		generate num_new_affiliates = weight * new_affiliate



		***************
		// More detailed aggregates for these states, as they are not persistent.
		// Step 1: pre-generate indicators (gcollapse takes variable names, not expressions).
		// num_contributors/num_inactive are expressed as a share of the year (dens/12)
		// rather than a 0/1 flag, so they read as "average number of affiliates
		// contributing" once summed.
		tempvar _alive _contrib _inactive
		generate `_alive'    = (status != 99)
		generate `_contrib'  = (dens / 12)        * (status != 99)
		generate `_inactive' = ((12 - dens) / 12) * (status != 99)

		// Step 2-3: totals by id. With annual data there is one row per id, so the id-level totals are the row's own values
		// (collapsing by id and joining back is only needed if an id has several rows).
		capture gisid id
		if _rc == 0 {
			generate double num_exiters      = exiter
			generate double num_reentrants   = reentrant
			generate double num_affiliates   = `_alive'
			generate double num_contributors = `_contrib'
			generate double num_inactive     = `_inactive'
		}
		else {
			// Step 2: collapse to id-level totals in a single pass
			preserve
				gcollapse (sum) num_exiters=exiter     ///
								num_reentrants=reentrant  ///
								num_affiliates=`_alive'   ///
								num_contributors=`_contrib' ///
								num_inactive=`_inactive'  ///
						  , by(id)
				tempfile id_agg_yr
				save `id_agg_yr', replace
			restore

			// Step 3: join back onto the full dataset (one row per id this year)
			join num_exiters num_reentrants num_affiliates num_contributors num_inactive, from(`id_agg_yr') by(id) keep(1 3) nogenerate
		}

		// Step 4: apply weights and scaling
		// Note (ANNUAL DATA): no /12 here - there is only one row per id this year (not 12), and
		// num_contributors/num_inactive are already fraction-of-year scaled above.
		replace num_exiters      = weight * num_exiters
		replace num_reentrants   = weight * num_reentrants
		replace num_affiliates   = weight * num_affiliates
		replace num_contributors = weight * num_contributors
		replace num_inactive     = weight * num_inactive

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
		// Note: `sumvars' uses the samplesize=weight rename, valid only for the
		// FIRST (finest-grain) gcollapse below, where `weight' still exists as its
		// own variable. `sumvars_rollup' is the post-rename equivalent (the
		// variable is already called `samplesize' in `finest_grain_yr'), used for
		// every subsequent rollup.
		local sumvars  		= "num_new_affiliates num_exiters num_reentrants num_affiliates num_contributors num_inactive retired disabled widowed deceased samplesize=weight"
		local sumvars_rollup = "num_new_affiliates num_exiters num_reentrants num_affiliates num_contributors num_inactive retired disabled widowed deceased samplesize"
		local meanvars 		= "los loa wage contribution_density"
		local var_order		= "year age gender wage_decile dens samplesize num_affiliates num_contributors num_inactive num_new_affiliates num_exiters num_reentrants retired disabled widowed deceased los loa wage contribution_density"


		***************
		// Compute the finest-grain breakdown (age x gender x wage_decile x dens) ONCE.
		// Carries sums of `meanvars' (renamed *_sum) plus a row count (n_obs) and an
		// age*n_obs helper (age_sum, for the grand total's avg_age), so every coarser
		// breakdown can recover the correct (unweighted, per-person) mean via sum/n_obs -
		// mathematically identical to computing `collapse (mean)' directly.
		preserve
			gcollapse (sum) `sumvars' 									///
							 los_sum=los loa_sum=loa 						///
							 wage_sum=wage cod_sum=contribution_density	///
					  (count) n_obs=id										///
					  (mean)  population_total working_age_total 			///
							  target_employment_rate target_turnover_rate	///
					  , by(age gender wage_decile dens)
			generate double age_sum = age * n_obs

			local sumvars_plus_helpers = "`sumvars_rollup' los_sum loa_sum wage_sum cod_sum age_sum n_obs"

			// CUBE TRICK: all 15 rollups + the grand total computed via a SINGLE combined
			// gcollapse instead of 16 separate gcollapse+save cycles. Each rollup's
			// not-included dimensions are relabeled to the usual 99/999 placeholder before
			// stacking all 16 relabeled copies (15 rollups + the grand total, which is just
			// the "every dim placeholder" 16th combination) into one dataset; a single
			// gcollapse by (age gender wage_decile dens) then recovers every rollup's
			// numbers at once, since no two rollups (or the grand total) share the same
			// real-vs-placeholder pattern, so their rows can never collide in the final
			// grouped result.

			local rollup_1  = "age gender wage_decile dens"	// age, decile, gender, and contribution status
			local rollup_2  = "gender wage_decile age"			// age, gender, and wage decile
			local rollup_3  = "age wage_decile dens"			// decile, age, and contribution status
			local rollup_4  = "gender age dens"				// age, gender, and contribution status
			local rollup_5  = "gender wage_decile dens"		// decile, gender, and contribution status
			local rollup_6  = "age wage_decile"				// decile and age
			local rollup_7  = "gender age"						// age and gender
			local rollup_8  = "age dens"						// age and contribution density
			local rollup_9  = "gender wage_decile"				// decile and gender
			local rollup_10 = "wage_decile dens"				// decile and contribution status
			local rollup_11 = "gender dens"					// gender and contribution status
			local rollup_12 = "age"								// age
			local rollup_13 = "wage_decile"						// decile
			local rollup_14 = "gender"							// gender totals
			local rollup_15 = "dens"							// contribution status

			// All rollups and the grand total in memory: relabelled copies of the finest-grain table are stacked and collapsed once
			generate long _row = _n
			expand 16
			bysort _row: generate byte _c = _n
			forvalues r = 1/15 {
				if !strpos(" `rollup_`r'' ", " age ") replace age = 999 if _c == `r'
				if !strpos(" `rollup_`r'' ", " gender ") replace gender = 99 if _c == `r'
				if !strpos(" `rollup_`r'' ", " wage_decile ") replace wage_decile = 99 if _c == `r'
				if !strpos(" `rollup_`r'' ", " dens ") replace dens = 99 if _c == `r'
			}
			replace age = 999 if _c == 16
			replace gender = 99 if _c == 16
			replace wage_decile = 99 if _c == 16
			replace dens = 99 if _c == 16
			drop _row _c
			gcollapse (sum) `sumvars_plus_helpers' (mean) population_total working_age_total target_employment_rate target_turnover_rate, by(age gender wage_decile dens)

			generate year = `yr'
			generate avg_age              = age_sum / n_obs
			generate los                  = los_sum / n_obs
			generate loa                  = loa_sum / n_obs
			generate wage                 = wage_sum / n_obs
			generate contribution_density = cod_sum / n_obs
			// "Employment rate": Share of affiliates who are working
			generate employment_rate 	= 100 * num_contributors / num_affiliates
			// Share of people changing roles each year: (exiters + reentrants) / affiliates
			generate turnover_rate 	= 100 * (num_exiters + num_reentrants) / (num_affiliates * 12)
			drop los_sum loa_sum wage_sum cod_sum age_sum n_obs

			tempfile cube_combined
			save `cube_combined', replace

			***************
			// Split the combined cube back into the two separate products the rest
			// of the pipeline expects: the 15-rollup BREAKDOWNS file (no avg_age,
			// matching the original per-rollup output exactly) and the single-row
			// grand TOTAL file (with avg_age) - same two destinations as before.
			use `cube_combined', clear
			keep if !(age == 999 & gender == 99 & wage_decile == 99 & dens == 99)
			drop avg_age
			order `var_order'
			tempfile rpt_temp
			save `rpt_temp', replace
			local breakdown_files_list = "`breakdown_files_list' `rpt_temp'"

			use `cube_combined', clear
			keep if (age == 999 & gender == 99 & wage_decile == 99 & dens == 99)
			order year age gender wage_decile dens  							///
			samplesize num_affiliates num_contributors num_inactive 			///
			num_new_affiliates num_exiters num_reentrants  						///
			retired disabled widowed deceased  									///
			avg_age los loa wage contribution_density 							///
			population_total working_age_total 							 		///
			target_employment_rate employment_rate								///
			target_turnover_rate turnover_rate
			tempfile rpt_temp2
			save `rpt_temp2', replace
			local total_files_list = "`total_files_list' `rpt_temp2'"
		restore
				


		
		************************************************************************
		************************************************************************
		timer off 17
		timer on 18
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
				 minimum_pension life_expectancy wage wage_ref wage_retired gets_lumpsum pension_class_switch ///
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
	

	
		timer off 18
	} // end forvalues yr
	****************************************************************************
	****************************************************************************
	****************************************************************************
	****************************************************************************
	****************************************************************************
timer on 19

***************
// Combine all 24 years' in-year reporting into the final tempfiles used at
// export time below - a single combined append instead of re-reading/
// appending/re-saving the whole growing reporting file every year (see the
// restructuring note in Stage 13 above).
preserve
	clear
	foreach f of local total_files_list {
		append using "`f'"
	}
	save `inyear_affiliate_reporting_tot', replace
restore

preserve
	clear
	foreach f of local breakdown_files_list {
		append using "`f'"
	}
	save `inyear_affiliate_reporting', replace
restore

//	Compress the dataset (for size constraints)
	compress, nocoalesce

********************************************************************************
//	Final reporting on the affiliate database
	// Clean up tempvars before saving
	capture drop __00*
	
	// Move all the annual wage variables to the back
	*order wage_????, last
	
	
	// Export the data (.dta only - smaller and reads back without type-inference)
	*cd "`outdir'"
	save "`outdir'\1_PROSTv2-`simname'-Affiliates-`startyear'-`endyear'.dta", replace



	// [Sanity check: Output histograms of contribution density by decile]
	// Save histogram to compare with simulated density in the last year
	if `histograms' == 1 {
		local histogram_outdir = "C:\Users\Duncan\OneDrive\World Bank\Generic\Output\Annual Model Sept 16\Very Low Approach"

		histogram contribution_density, name(cod_lastyear, replace) yscale(range(0 5))
		graph combine cod_baseyear cod_lastyear, name(aggregate, replace) ycommon
		graph export "`histogram_outdir'\aggregate.jpg", name(aggregate) replace

		histogram contribution_density if !missing(new_affiliate_flag), name(cod_lastyear_new, replace) yscale(range(0 5))
		graph combine cod_baseyear cod_lastyear_new, name(aggregate_new, replace) ycommon
		graph export "`histogram_outdir'\aggregate_new.jpg", name(aggregate_new) replace

		histogram contribution_density, by(wage_decile_ref) name(cod_by_decile_lastyear, replace) yscale(range(0 15))
		graph combine cod_by_decile_baseyear cod_by_decile_lastyear, name(by_decile, replace) ycommon
		graph export "`histogram_outdir'\by_decile.jpg", name(by_decile) replace

		histogram contribution_density if !missing(new_affiliate_flag), by(wage_decile_ref) name(cod_by_decile_lastyear_new, replace) yscale(range(0 15))
		graph combine cod_by_decile_baseyear cod_by_decile_lastyear_new, name(by_decile_new, replace) ycommon
		graph export "`histogram_outdir'\by_decile_new.jpg", name(by_decile_new) replace

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

timer off 19
timer on 20
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
	


	

timer off 20
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
		timer on 21
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
		timer off 21
		timer on 22
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
		// New pensioners (startyear == this year) already faced this year's mortality as affiliates (Stage 2 of the affiliate loop)
		replace died_flag = 1 		if mortality > `randnum_mortality' & status != 99 & startyear < `yr'
		replace deathyear = `yr'	if died_flag == 1 // Record year died
		*replace status = 99 		if died_flag == 1 // Status 99 means dead
		
		// Housekeeping for dead people
		replace db_pension_benefit 	= . if died_flag == 1
		replace dc_pension_benefit 	= . if died_flag == 1
		replace pension_benefit 	= . if died_flag == 1
		replace age_died = age 		    if died_flag == 1
	
	
	
		************************************************************************
		************************************************************************
		timer off 22
		timer on 23
		// Stage 3: Index pension benefits and reference wages
		// After retirement, the pension evolves according to the indexation rule.
		// Pension_i (t) = Pension_i (t-1) * (1+PensionIndexationRate(t))
		// PensionIndexationRate(t) = α_1 * Inflation(t-1) + α_2 * RealWageGrowth(t-1) + α_3 * AnchorVariable(t)
		
		capture drop pindex_inflation pindex_realwage pindex_anchor
		// Cap merge year so projection years beyond data use the last available indexation values
		capture drop year_merge
		// Use the projection year, not the row-level year: new pensioners carry a year one behind the pensioner stock, and the average over rows would mix two years
		generate year_merge = min(`yr', `indexation_max_year')
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
		// A pension is first indexed in the year after it starts (unless index_in_start_year == 1)
		replace db_pension_benefit = db_pension_benefit * (1 + pension_index) if startyear < `yr' | `index_in_start_year' == 1

		// DC pension indexation (applied only if dc_annuity_indexed == 1)
		if `dc_annuity_indexed' {
			replace dc_pension_benefit = dc_pension_benefit * (1 + pension_index) if dc_pension_benefit > 0 & (startyear < `yr' | `index_in_start_year' == 1)
		}

		// The top-up to the minimum pension (government subsidy) moves with the pension it tops up
		// (DC top-ups only if the DC pension is indexed)
		capture confirm variable gov_minpen_subsidy
		if _rc generate gov_minpen_subsidy = .
		capture confirm variable pension_class_switch
		if _rc generate byte pension_class_switch = 0
		replace pension_class_switch = 0 if missing(pension_class_switch)
		replace gov_minpen_subsidy = gov_minpen_subsidy * (1 + pension_index) 		///
			if !missing(gov_minpen_subsidy) & (startyear < `yr' | `index_in_start_year' == 1) ///
			 & (pension_class == 1 | (pension_class == 2 & `dc_annuity_indexed' == 1))
		
		//	Update the overall pension benefit
		replace pension_benefit = dc_pension_benefit + db_pension_benefit
		replace pension_benefit = . if gets_lumpsum == 1



		************************************************************************
		************************************************************************
		timer off 23
		timer on 24
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
		//
		//	Reporting is split into two "cubes" (16 non-wage combos of {gender,age_grp,
		//	pension_class,pension_type}, plus 16 wage-inclusive combos of the same 4
		//	dims with wage_decile_ret always included, on a differently-filtered
		//	sample). Each cube's finest grain is computed ONCE via gcollapse, and every
		//	coarser breakdown within that cube is derived from it (same CUBE TRICK
		//	approach as Stage 13). Means are reconstructed as sum/count, mathematically
		//	identical to `collapse (mean)'. Each year's files are saved to tempfiles
		//	and combined once after the main loop ends.

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


		local sumvars 	= "newly_retired retired disabled widowed deceased has_min_pension has_lumpsum government_pension_subsidy"
		// meanvars, as originally computed (unweighted per-person means); *_sum
		// versions (below) are the sums needed to reconstruct them at any rollup.
		local meanvar_names = "avg_pension replacement_rate income_adequacy db_years_early db_years_late average_wage reference_wage"
		local meanvar_sources = "pension_benefit replacement_rate income_adequacy db_years_early db_years_late average_wage reference_wage"

		***************
		// Cube A (non-wage): finest grain = gender age_grp pension_class pension_type,
		// if status!=99.
		preserve
			gcollapse (sum) `sumvars' 												///
							 avg_pension_sum=pension_benefit 						///
							 replacement_rate_sum=replacement_rate 				///
							 income_adequacy_sum=income_adequacy					///
							 db_years_early_sum=db_years_early						///
							 db_years_late_sum=db_years_late						///
							 average_wage_sum=average_wage							///
							 reference_wage_sum=reference_wage						///
					  (count) n_obs=year											///
					  if status != 99, by(gender age_grp pension_class pension_type)

			local sumvars_plus_sums = "`sumvars' avg_pension_sum replacement_rate_sum income_adequacy_sum db_years_early_sum db_years_late_sum average_wage_sum reference_wage_sum n_obs"

			// CUBE TRICK (same technique as Stage 13's affiliate reporting above): all 15
			// rollups + the grand total computed via a single combined gcollapse.

			local rollupA_1  = "gender age_grp pension_class pension_type"	// = pension_age_sex_class_type
			local rollupA_2  = "gender age_grp pension_class"					// = pension_age_sex_class
			local rollupA_3  = "gender age_grp pension_type"					// = pension_age_sex_type
			local rollupA_4  = "age_grp pension_class pension_type"			// = pension_age_class_type
			local rollupA_5  = "gender pension_class pension_type"			// = pension_sex_class_type
			local rollupA_6  = "gender age_grp"								// = pension_age_sex
			local rollupA_7  = "gender pension_class"							// = pension_sex_class
			local rollupA_8  = "gender pension_type"							// = pension_sex_type
			local rollupA_9  = "age_grp pension_class"							// = pension_age_class
			local rollupA_10 = "age_grp pension_type"							// = pension_age_type
			local rollupA_11 = "pension_class pension_type"					// = pension_class_type
			local rollupA_12 = "gender"										// = pension_sex
			local rollupA_13 = "age_grp"										// = pension_age
			local rollupA_14 = "pension_class"									// = pension_class
			local rollupA_15 = "pension_type"									// = pension_type

			// All rollups and the grand total in memory: relabelled copies of the finest-grain table are stacked and collapsed once
			generate long _row = _n
			expand 16
			bysort _row: generate byte _c = _n
			forvalues r = 1/15 {
				if !strpos(" `rollupA_`r'' ", " gender ") replace gender = 99 if _c == `r'
				if !strpos(" `rollupA_`r'' ", " age_grp ") replace age_grp = 999 if _c == `r'
				if !strpos(" `rollupA_`r'' ", " pension_class ") replace pension_class = 999 if _c == `r'
				if !strpos(" `rollupA_`r'' ", " pension_type ") replace pension_type = 999 if _c == `r'
			}
			replace gender = 99 if _c == 16
			replace age_grp = 999 if _c == 16
			replace pension_class = 999 if _c == 16
			replace pension_type = 999 if _c == 16
			drop _row _c
			gcollapse (sum) `sumvars_plus_sums', by(gender age_grp pension_class pension_type)

			generate year = `yr'
			generate wage_decile_ret = 99	// Totals placeholder - non-wage cube never has this
			generate avg_pension       = avg_pension_sum / n_obs
			generate replacement_rate  = replacement_rate_sum / n_obs
			generate income_adequacy   = income_adequacy_sum / n_obs
			generate db_years_early    = db_years_early_sum / n_obs
			generate db_years_late     = db_years_late_sum / n_obs
			generate average_wage      = average_wage_sum / n_obs
			generate reference_wage    = reference_wage_sum / n_obs
			drop avg_pension_sum replacement_rate_sum income_adequacy_sum db_years_early_sum db_years_late_sum average_wage_sum reference_wage_sum n_obs

			tempfile cubeA_combined
			save `cubeA_combined', replace

			***************
			// Split: breakdowns (15 rollups) go to the running `breakdown_files' list,
			// the grand total (all 4 dims placeholder) goes straight to the separate
			// TOTALS accumulator - same two destinations as before.
			use `cubeA_combined', clear
			keep if !(gender == 99 & age_grp == 999 & pension_class == 999 & pension_type == 999)
			tempfile rpt_temp
			save `rpt_temp', replace
			local breakdown_files = "`rpt_temp'"

			use `cubeA_combined', clear
			keep if (gender == 99 & age_grp == 999 & pension_class == 999 & pension_type == 999)
			tempfile rpt_temp2
			save `rpt_temp2', replace
			local pension_total_files_list = "`pension_total_files_list' `rpt_temp2'"
		restore

		***************
		// Cube B (wage-inclusive): finest grain = wage_decile_ret gender age_grp
		// pension_class pension_type, if status!=99 & wage_decile_ret not missing.
		preserve
			gcollapse (sum) `sumvars' 												///
							 avg_pension_sum=pension_benefit 						///
							 replacement_rate_sum=replacement_rate 				///
							 income_adequacy_sum=income_adequacy					///
							 db_years_early_sum=db_years_early						///
							 db_years_late_sum=db_years_late						///
							 average_wage_sum=average_wage							///
							 reference_wage_sum=reference_wage						///
					  (count) n_obs=year											///
					  if status != 99 & !missing(wage_decile_ret), by(wage_decile_ret gender age_grp pension_class pension_type)

			// CUBE TRICK (same technique as Cube A above): all 16 rollups computed via a
			// single combined gcollapse. wage_decile_ret is always real (never placeholder)
			// in this cube, so only gender/age_grp/pension_class/pension_type vary across
			// the 16 combinations - no separate grand total here, since Cube A already
			// provides the true non-wage-sliced grand total.

			local rollupB_1  = "wage_decile_ret"											// = pension_wage
			local rollupB_2  = "wage_decile_ret gender"									// = pension_wage_sex
			local rollupB_3  = "wage_decile_ret age_grp"									// = pension_wage_age
			local rollupB_4  = "wage_decile_ret pension_class"								// = pension_wage_class
			local rollupB_5  = "wage_decile_ret pension_type"								// = pension_wage_type
			local rollupB_6  = "wage_decile_ret gender age_grp"							// = pension_wage_sex_age
			local rollupB_7  = "wage_decile_ret gender pension_class"						// = pension_wage_sex_class
			local rollupB_8  = "wage_decile_ret gender pension_type"						// = pension_wage_sex_type
			local rollupB_9  = "wage_decile_ret age_grp pension_class"						// = pension_wage_age_class
			local rollupB_10 = "wage_decile_ret age_grp pension_type"						// = pension_wage_age_type
			local rollupB_11 = "wage_decile_ret pension_class pension_type"					// = pension_wage_class_type
			local rollupB_12 = "wage_decile_ret gender age_grp pension_class"				// = pension_wage_sex_age_class
			local rollupB_13 = "wage_decile_ret gender age_grp pension_type"				// = pension_wage_sex_age_type
			local rollupB_14 = "wage_decile_ret gender pension_class pension_type"			// = pension_wage_sex_class_type
			local rollupB_15 = "wage_decile_ret age_grp pension_class pension_type"			// = pension_wage_age_class_type
			local rollupB_16 = "wage_decile_ret gender age_grp pension_class pension_type"	// = pension_wage_sex_age_class_type

			// All rollups in memory: relabelled copies of the finest-grain table are stacked and collapsed once
			generate long _row = _n
			expand 16
			bysort _row: generate byte _c = _n
			forvalues r = 1/16 {
				if !strpos(" `rollupB_`r'' ", " gender ") replace gender = 99 if _c == `r'
				if !strpos(" `rollupB_`r'' ", " age_grp ") replace age_grp = 999 if _c == `r'
				if !strpos(" `rollupB_`r'' ", " pension_class ") replace pension_class = 999 if _c == `r'
				if !strpos(" `rollupB_`r'' ", " pension_type ") replace pension_type = 999 if _c == `r'
			}
			drop _row _c
			gcollapse (sum) `sumvars_plus_sums', by(wage_decile_ret gender age_grp pension_class pension_type)

			generate year = `yr'
			generate avg_pension       = avg_pension_sum / n_obs
			generate replacement_rate  = replacement_rate_sum / n_obs
			generate income_adequacy   = income_adequacy_sum / n_obs
			generate db_years_early    = db_years_early_sum / n_obs
			generate db_years_late     = db_years_late_sum / n_obs
			generate average_wage      = average_wage_sum / n_obs
			generate reference_wage    = reference_wage_sum / n_obs
			drop avg_pension_sum replacement_rate_sum income_adequacy_sum db_years_early_sum db_years_late_sum average_wage_sum reference_wage_sum n_obs

			tempfile rpt_temp
			save `rpt_temp', replace
			local breakdown_files = "`breakdown_files' `rpt_temp'"
		restore

		local pension_breakdown_files_list = "`pension_breakdown_files_list' `breakdown_files'"

		// Chart data (output_charts): compact aggregates of the pensioner stock, and the new retirees, of this year
		if `output_charts' == 1 {
			frame put pension_class pension_type gender age wage_decile_ret pension_benefit gov_minpen_subsidy minimum_pension reference_wage weight ///
				if status != 99 & died_flag != 1, into(chartf)
			frame chartf {
				quietly {
					generate double n          = weight
					generate double n_pay      = weight * (pension_benefit > 0 & !missing(pension_benefit))
					generate double ben_sum    = weight * pension_benefit if pension_benefit > 0 & !missing(pension_benefit)
					generate byte   has_sub    = (gov_minpen_subsidy > 0 & !missing(gov_minpen_subsidy))
					generate double sub_sum    = weight * gov_minpen_subsidy * has_sub
					generate double sub_n      = weight * has_sub
					generate double subpct_sum = weight * 100 * gov_minpen_subsidy / reference_wage if has_sub == 1 & reference_wage > 0 & !missing(reference_wage)
					generate double min_n      = weight * (minimum_pension == 1)
					gcollapse (sum) n n_pay ben_sum sub_sum sub_n subpct_sum min_n, by(pension_class pension_type gender age wage_decile_ret)
					generate year = `yr'
					tempfile chart_stock_`yr'
					save `chart_stock_`yr'', replace
				}
			}
			frame drop chartf
			local chart_stock_files = "`chart_stock_files' `chart_stock_`yr''"

			frame put pension_class gender age_retired wage_decile_ret gets_lumpsum minimum_pension gov_minpen_subsidy pension_benefit ///
				replacement_rate income_adequacy life_expectancy reference_wage average_wage weight ///
				if status == 2 & startyear == `yr' & pension_type == 1, into(chartn)
			frame chartn {
				quietly generate year = `yr'
				tempfile chart_newret_`yr'
				quietly save `chart_newret_`yr'', replace
			}
			frame drop chartn
			local chart_newret_files = "`chart_newret_files' `chart_newret_`yr''"
		}
		
		


		// Drop reporting variables
		capture drop retired
		capture drop disabled
		capture drop widowed
		capture drop deceased	

		
		
		************************************************************************
		************************************************************************
		timer off 24
		timer on 25
		// Stage 5: Update values
		replace age     = age  + 1 if status != 99
		replace age_grp = floor(age / 5) * 5
		replace year    = year + 1
		
		// Update status for those who recently died
		replace status = 99 		if died_flag == 1 // Status 99 means dead

		
		
		timer off 25
		} // end forvalues yr
timer on 26

***************
// Combine all years' pensioner in-year reporting into the final tempfiles used
// at export time below - a single combined append instead of re-reading/
// appending/re-saving the whole growing reporting file every year (see the
// restructuring note in pensioner Stage 4 above).
preserve
	clear
	foreach f of local pension_total_files_list {
		append using "`f'"
	}
	save `inyear_pension_reporting_tot', replace
restore

preserve
	clear
	foreach f of local pension_breakdown_files_list {
		append using "`f'"
	}
	save `inyear_pension_reporting', replace
restore

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


************************************************************************
//	OUTPUT CHARTS: save the chart data and build the charts and the Excel files
if `output_charts' == 1 {
	local chartdir = "`charts_dir'/`simname'"
	capture mkdir "`charts_dir'"
	capture mkdir "`chartdir'"
	preserve
		clear
		foreach f of local chart_stock_files {
			append using "`f'"
		}
		save "`chartdir'/chart_stock.dta", replace
		clear
		foreach f of local chart_newret_files {
			append using "`f'"
		}
		save "`chartdir'/chart_newret.dta", replace
	restore
	do "`chart_script'" "`outdir'" "`simname'" "`chartdir'" "`indir'/`gdp_data'" "`chart_label_db'" "`chart_label_dc'" "`chart_years'" "`chart_gdp_real_growth'" "`wagegrowdir'/`wage_grow_data'"
}


************************************************************************
// 	Timer summary: identify which section of the code takes the longest.
//	Uses Mata's timer_value() to pull each timer's accumulated seconds
//	(timer on/off with the same number accumulates automatically across
//	all `forvalues yr' iterations, so each row below is a TOTAL across the
//	whole horizon, not a single year).
************************************************************************
timer off 26
timer off 1

	preserve
		clear
		set obs 26
		generate timer_num = _n
		generate section = ""
		replace section = "01 - TOTAL (whole script)"                                  if timer_num == 1
		replace section = "02 - Initialization (STEP 0.1-1.12)"                        if timer_num == 2
		replace section = "03 - Baseyear setup (STEP 2)"                               if timer_num == 3
		replace section = "04 - Affiliate loop: Stage 00 (DC policy carry-forward)"     if timer_num == 4
		replace section = "05 - Affiliate loop: Stage 0 (DB policy carry-forward)"      if timer_num == 5
		replace section = "06 - Affiliate loop: Stage 1 (new affiliates)"               if timer_num == 6
		replace section = "07 - Affiliate loop: Stage 2 (project forward)"              if timer_num == 7
		replace section = "08 - Affiliate loop: Stage 3 (compute variables)"            if timer_num == 8
		replace section = "09 - Affiliate loop: Stage 4 (mortality)"                    if timer_num == 9
		replace section = "10 - Affiliate loop: Stage 5 (transition hazards / wage dynamics)"  if timer_num == 10
		replace section = "11 - Affiliate loop: Stage 6 (mortality)"                    if timer_num == 11
		replace section = "12 - Affiliate loop: Stage 7 (disability/survivor)"          if timer_num == 12
		replace section = "13 - Affiliate loop: Stage 8 (indexation)"                   if timer_num == 13
		replace section = "14 - Affiliate loop: Stage 9 (DC iacc update)"               if timer_num == 14
		replace section = "15 - Affiliate loop: Stage 10 (DB pension layers)"           if timer_num == 15
		replace section = "16 - Affiliate loop: Stage 11 (retirement decision)"         if timer_num == 16
		replace section = "17 - Affiliate loop: Stage 13 (in-year reporting)"           if timer_num == 17
		replace section = "18 - Affiliate loop: Stage 14 (save pension-transition db)"  if timer_num == 18
		replace section = "19 - Affiliate post-loop (export + histograms)"              if timer_num == 19
		replace section = "20 - Pensioner baseyear setup"                               if timer_num == 20
		replace section = "21 - Pensioner loop: Stage 1 (append year)"                  if timer_num == 21
		replace section = "22 - Pensioner loop: Stage 2 (mortality)"                    if timer_num == 22
		replace section = "23 - Pensioner loop: Stage 3 (indexation)"                   if timer_num == 23
		replace section = "24 - Pensioner loop: Stage 4 (in-year reporting)"            if timer_num == 24
		replace section = "25 - Pensioner loop: Stage 5 (update values)"                if timer_num == 25
		replace section = "26 - Final reporting/export"                                 if timer_num == 26

		generate double seconds = .
		quietly forvalues t = 1/26 {
			mata: st_store(`t', "seconds", timer_value(`t')[1,1])
		}
		gsort -seconds

		list section seconds, sep(0) noobs

		local timing_logpath = "`outdir'\1_PROSTv2-`simname'-Timing-Profile.txt"
		capture file close tfile
		file open tfile using "`timing_logpath'", write replace
		file write tfile "Timing profile - `simname'  (horizon=`horizon', samplesize=`samplesize'pct)" _n
		file write tfile "Sorted by total elapsed seconds, most expensive section first" _n
		file write tfile "================================================================" _n
		quietly count
		local nrows = r(N)
		forvalues i = 1/`nrows' {
			local sec_label = section[`i']
			local sec_time  = seconds[`i']
			file write tfile %-58s "`sec_label'" %12.2f (`sec_time') " sec" _n
		}
		file close tfile

		noisily display as result _n "Timing profile saved to: `timing_logpath'"
	restore

timer list