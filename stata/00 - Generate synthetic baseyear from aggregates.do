/*******************************************************************************
Title:			Generate Synthetic Baseyear Dataset from Aggregate Targets
Author:			Duncan MacDonald
Description:	Samples individuals from baseyear microdata and rescales wages
				and individual account balances so that cell-level statistics
				(by age × gender) match the target aggregates:
				  - Number of affiliates       (numA)
				  - contrA contributors (Afore/DC) by age × gender
				  - contrT contributors (Transición/DB) by age × gender
				  Note: all baseyear individuals are Afore; contrT individuals are
				  synthetically re-labelled to match the DB target counts.
				  - Average monthly wage       (wage)
				  - Average individual account (iacc)
					Targets are rebased from the year of the data to the base year of the projection (see REBASING in Section 0).

Inputs:
  Input/baseyear_data_MEX.dta    - Individual monthly microdata (12 obs/person)
  Input/001-Data Aggregates.dta  - Target aggregates by age × gender

Output:
  Output/synthetic_baseyear.dta  - Synthetic dataset matching aggregate targets

Requires: gtools  (ssc install gtools)
*******************************************************************************/

//	INITIALIZATION
	clear all
	pause on
	set trace off


// =============================================================================
//	SECTION 0: USER PARAMETERS  
// =============================================================================

	//	Final dataset size as a fraction of the full matched dataset.
	//	1.0 = keep everything; 0.1 = random 10% sample of the result.
	local sample_fraction = 0.10
	local sample_name = round(100 * `sample_fraction')

	//	Random seed for reproducibility
	local seed = 12345

	//	REBASING TO THE BASE YEAR OF THE PROJECTION
	//	The microdata and the aggregates are for `data_year' (wages, balances and benefits in `data_year' pesos). The projection
	//	starts from `base_year' and compares wages with minimum-wage based parameters (minimum pension, UMA/SM brackets) of its own years.
	//	rebase = 1: wages, the individual account balances (iacc) are moved from `data_year' to `base_year' with the cumulative growth rates in `wage_growth_file'
	//	            (wage_growth = nominal wage growth, cpi = inflation, both in %). 0 = leave the values in `data_year' pesos.
	local rebase           = 1
	local data_year        = 2020
	local base_year        = 2024
	local country          = "MEX"
	local wage_growth_file = "wage_growth_`country'.csv"

	//	PRE-1997 SERVICE CREDIT (transition generation, defined-benefit class)
	//	The microdata record affiliation and service only from July 1997 (left-censored), but the DB pension counts the whole career.
	//	pre97_credit = 1 imputes, for every person assigned to the DB class, the affiliation and service BEFORE July 1997:
	//	  - DB class = affiliated before July 1997. Within each age x gender cell the contrT contributors with the longest observed
	//	    affiliation (loa) are assigned to DB (those present at the start of the record are the most likely pre-1997 affiliates), the
	//	    rest of the contributors to DC (Afore). The number of DB and DC contributors in each cell is still contrA / contrT exactly.
	//	  - affiliation before July 1997 = age in July 1997 less the age at first affiliation (random between the min and max below, by gender)
	//	  - service before July 1997 = that affiliation x the observed contribution density (los / loa) x pre97_density_mult
	//	    (1 = the density before 1997 is the one observed since; > 1 = denser career before 1997), at most 100%
	//	The credit is added to los and loa of DB-class persons (the DC account balance is not changed). DC persons get no credit.
	local pre97_credit        = 1
	local pre97_start_min_m   = 16		// Age at first affiliation, men: minimum
	local pre97_start_max_m   = 26		// Age at first affiliation, men: maximum
	local pre97_start_min_f   = 17		// Age at first affiliation, women: minimum
	local pre97_start_max_f   = 28		// Age at first affiliation, women: maximum
	local pre97_density_mult  = 1.0
	
	// File locations
	local indir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"	// User inputs

	//	File paths
	local baseyear_file   "baseyear_data_MEX.dta"
	local aggregates_file "001-Data Aggregates.dta"
	local output_file     "synthetic_affiliates_`sample_name'pct_sample.dta"
	local weight_file     "synthetic_weights_`sample_name'pct_sample.dta"


	//	Create output folder if needed
	capture mkdir "Output"

	set seed `seed'

	//	Rebasing indices: cumulative growth between the year of the data and the base year
	local wage_index = 1
	local cpi_index  = 1
	if `rebase' == 1 {
		import delimited "`indir'/`wage_growth_file'", clear
		keep if iso3 == "`country'" & inrange(year, `data_year' + 1, `base_year')
		assert _N == `base_year' - `data_year'
		generate double ln_w = ln(1 + wage_growth / 100)
		generate double ln_c = ln(1 + cpi / 100)
		quietly summarize ln_w
		local wage_index = exp(r(sum))
		quietly summarize ln_c
		local cpi_index  = exp(r(sum))
		display as result "Rebasing `data_year' to `base_year': wage index = " %6.4f `wage_index' " | CPI index = " %6.4f `cpi_index'
		clear
	}


// =============================================================================
//	SECTION 1: BUILD INDIVIDUAL-LEVEL POOL FROM BASEYEAR
// =============================================================================

	// Open the dataset
	cd "`indir'"
	use "`baseyear_file'", clear
	
	
	//	Individual-level summaries (constant within person)
	bysort id: egen ever_contr       = max(dens)                    // 1 if contributed any month
	bysort id: egen avg_wage_ind     = mean(wage)  		            // mean wage while contributing
	bysort id: egen iacc_dec_ind     = max(iacc * (month == 12))    // December balance

	// Compute the person's reference wage
	// Note: this is capped by observed min and max wages for working individuals
	summ avg_wage_ind
	local avg_wage = r(mean)
	local min_wage = r(min)
	local max_wage = r(max)
	generate reference_wage = max(min(wage_relative_mean * `avg_wage', `max_wage'), `min_wage')
	replace  reference_wage = wage if !missing(wage)



	preserve
		//	Drop age and gender from the monthly file — these individual constants
		//	will come from sampled_indiv via joinby, which is necessary so that
		//	individuals imputed for missing cells carry the correct target age
		drop age gender

		//	Save full monthly data (we will join back to this later)
		sort id month
		tempfile monthly_full
		save `monthly_full'
	restore

	//	One observation per individual for the sampling step
	keep if month == 12
	rename (loa los) (loa_dec los_dec)			// affiliation and service at the end of the data year (used for the DB/DC assignment and the pre-1997 credit)
	keep id age gender ever_contr avg_wage_ind iacc_dec_ind reference_wage loa_dec los_dec

	tempfile indiv_pool
	save `indiv_pool'
	
// =============================================================================
//	SECTION 2: COMPUTE CURRENT CELL STATISTICS FROM BASEYEAR
// =============================================================================

	//	Current counts and means by cell
	collapse (count) current_affiliates   = id            ///
			 (sum)   current_contributors = ever_contr   ///
			 (mean)  current_wage         = avg_wage_ind  ///
			 (mean)  current_iacc         = iacc_dec_ind, ///
			 by(age gender)

	tempfile cur_agg
	save `cur_agg'



// =============================================================================
//	SECTION 3: LOAD TARGET AGGREGATES
// =============================================================================

	cd "`indir'"
	use "`aggregates_file'", clear

	//	Keep contrA and contrT separately — both are matched from the baseyear pool
	//  contrT individuals are synthetically re-labelled
	keep age gender numA contrA contrT wage iacc
	rename (numA contrA contrT wage iacc) ///
		   (target_affiliates target_contrA target_contrT target_wage target_iacc)

	//	Drop cells with no target affiliates
	drop if missing(target_affiliates) | target_affiliates == 0

	//	Apply sample fraction up-front so all downstream expand/sampling
	//	steps work on the reduced target counts (much faster than building
	//	the full dataset and sampling at the end)
	if `sample_fraction' < 1 {
		replace target_affiliates = max(1, round(target_affiliates * `sample_fraction'))
		replace target_contrA     = max(0, round(target_contrA     * `sample_fraction'))
		replace target_contrT     = max(0, round(target_contrT     * `sample_fraction'))
		replace target_contrA     = min(target_contrA, target_affiliates)
		replace target_contrT     = min(target_contrT, target_affiliates - target_contrA)
	}

	//	Rebase the wage and account balance targets to the base year (the account balance is moved with wages, which keeps the
	//	ratio of balance to wage of the data year)
	replace target_wage = target_wage * `wage_index'
	replace target_iacc = target_iacc * `wage_index'

	generate target_contributors = target_contrA + target_contrT

	tempfile targets
	save `targets'


// =============================================================================
//	SECTION 3b: AUGMENT POOL FOR TARGET CELLS MISSING FROM BASEYEAR
// =============================================================================
//	Some target cells (e.g. ages >65, young females) have no observations in
//	the baseyear. For each such cell we find the nearest available age within
//	the same gender and copy those individuals into the pool, re-labelling
//	them with the target age. If a gender has no data at all, we fall back to
//	the nearest age in the opposite gender.

	//	Record which (age, gender) cells exist in the pool
	use `indiv_pool', clear
	keep age gender
	duplicates drop
	tempfile pool_cells
	save `pool_cells'

	//	Identify target cells absent from the pool
	use `targets', clear
	merge 1:1 age gender using `pool_cells', keep(master) nogenerate
	keep age gender
	count
	local n_missing = r(N)

	if `n_missing' > 0 {

		rename age target_age

		//	--- Pass 1: nearest age, same gender ---
		joinby gender using `pool_cells'
		generate _diff = abs(target_age - age)
		bysort target_age gender (_diff age): keep if _n == 1
		rename age donor_age
		//	gender variable = target gender = donor gender (same-gender match)
		tempfile donor_same
		save `donor_same'

		//	--- Pass 2: fallback for any target_age/gender still unmatched ---
		//	(occurs only when an entire gender is absent from the pool;
		//	in that case borrow from the nearest age across both genders)
		use `targets', clear
		merge 1:1 age gender using `pool_cells', keep(master) nogenerate
		keep age gender
		rename age target_age
		merge 1:1 target_age gender using `donor_same', keep(master) nogenerate
		count
		if r(N) > 0 {
			//	Rename pool variables to avoid name conflicts in cross-join
			preserve
				use `pool_cells', clear
				rename (age gender) (donor_age donor_gender)
				tempfile pool_all
				save `pool_all'
			restore
			cross using `pool_all'
			generate _diff = abs(target_age - donor_age)
			bysort target_age gender (_diff donor_age): keep if _n == 1
			drop _diff donor_gender
			append using `donor_same'
			save `donor_same', replace
		}

		//	--- Pull donor individuals and re-label with target age ---
		use `donor_same', clear
		//	donor_age and gender identify the pool rows to copy
		rename (donor_age gender) (age gender)
		joinby age gender using `indiv_pool'

		//	Overwrite age with the target age
		drop age
		rename target_age age

		//	Append imputed individuals to the pool
		append using `indiv_pool'
		save `indiv_pool', replace
	}


// =============================================================================
//	SECTION 4: SAMPLE INDIVIDUALS TO MATCH TARGET AFFILIATE COUNTS
// =============================================================================

	use `indiv_pool', clear

	//	Attach targets and current aggregates to every individual in the pool.
	//	cur_agg uses keep(match master) so that cells imputed in Section 3b
	//	(absent from the original baseyear) are retained with missing current_*
	//	values — those variables are informational only and not used in Step 4a.
	merge m:1 age gender using `targets', keep(match) nogenerate
	merge m:1 age gender using `cur_agg', keep(match master) nogenerate

	//	---------------------------------------------------------------------
	//	Step 4a: Sample contributors and non-contributors separately so that
	//	promoted/demoted status changes are avoided and every contributor
	//	has a valid avg_wage_ind.
	//	---------------------------------------------------------------------

	generate target_noncontr = target_affiliates - target_contributors


	//	--- Sample contributors from the contributor pool ---
	preserve
		keep if ever_contr == 1

		//	(1) Random shuffle + sample down
		generate _u = runiform()
		sort age gender _u
		by age gender: keep if _n <= target_contributors

		//	(2) Expand up where target > pool size
		bysort age gender: generate _cell_n = _N
		generate _rep = max(ceil(target_contributors / max(_cell_n, 1)), 1)
		expand _rep
		drop _rep _cell_n

		//	(3) Final trim to exactly target_contributors per cell
		sort age gender _u
		by age gender: keep if _n <= target_contributors
		drop _u

		tempfile sampled_contr
		save `sampled_contr'
	restore


	//	--- Sample non-contributors from the non-contributor pool ---
	//	For cells where the pool has no non-contributors, clone contributors from
	//	the same cell and re-label them so those cells can still hit their targets.
	bysort age gender: egen _has_noncontr = max(ever_contr == 0)
	generate _need_synthetic = (target_noncontr > 0 & _has_noncontr == 0 & ever_contr == 1)

	preserve
		keep if _need_synthetic == 1
		replace ever_contr   = 0
		replace avg_wage_ind = .
		replace iacc_dec_ind = 0
		tempfile synthetic_noncontr
		save `synthetic_noncontr', emptyok
	restore

	keep if ever_contr == 0
	keep if target_noncontr > 0

	append using `synthetic_noncontr'

	if _N > 0 {

		//	(1) Random shuffle + sample down
		generate _u = runiform()
		sort age gender _u
		by age gender: keep if _n <= target_noncontr

		//	(2) Expand up where target > pool size
		bysort age gender: generate _cell_n = _N
		generate _rep = max(ceil(target_noncontr / max(_cell_n, 1)), 1)
		expand _rep
		drop _rep _cell_n

		//	(3) Final trim to exactly target_noncontr per cell
		sort age gender _u
		by age gender: keep if _n <= target_noncontr
		drop _u

	}

	drop _has_noncontr _need_synthetic

	//	Reassemble both groups and assign synthetic IDs
	append using `sampled_contr'
	generate new_id = _n


	//	---------------------------------------------------------------------
	//	Step 4b: Rescale wages and iacc so that each cohort mean matches the
	//	target. A single cell-level multiplier is applied to every individual
	//	in the cell, preserving the relative distribution of wages and balances
	//	within the cohort while shifting the mean to the target value.
	//
	//	  scaled_wage_i = wage_i × (target_mean / sample_mean)
	//
	//	After this step: mean(scaled_wage) = target_wage  ✓
	//	                 relative dispersion is unchanged  ✓
	//	---------------------------------------------------------------------
	bysort age gender: egen _samp_wage = mean(avg_wage_ind)    // missing for non-contributors → contributor mean ✓

	//	Compute iacc sample mean over contributors only.
	//	Non-contributors (including synthetic ones) have iacc_dec_ind = 0, which
	//	would dilute the mean and inflate _scale_iacc if included.
	generate _iacc_contr = iacc_dec_ind if ever_contr == 1
	bysort age gender: egen _samp_iacc = mean(_iacc_contr)
	drop _iacc_contr

	generate _scale_wage = target_wage / _samp_wage
	generate _scale_iacc = target_iacc / _samp_iacc
	// Sparse cells (no contributors sampled) produce missing scale factors.
	// Set them to 1 so non-contributors keep their original value (zero iacc, original reference_wage)
	// rather than propagating missing through multiplication.
	replace _scale_wage = 1 if missing(_scale_wage)
	replace _scale_iacc = 1 if missing(_scale_iacc)

	replace avg_wage_ind     = avg_wage_ind     * _scale_wage if ever_contr == 1
	replace reference_wage   = reference_wage   * _scale_wage if ever_contr == 0
	replace iacc_dec_ind     = iacc_dec_ind     * _scale_iacc

	drop _samp_wage _samp_iacc


	//	---------------------------------------------------------------------
	//	Step 4c: Assign DB/DC pension class within each group.
	//	ever_contr is already correct from the split sampling — no reassignment.
	//	pre97_credit = 1: the DB class (Transicion) goes to the persons with the longest observed affiliation (loa) in the
	//	                  age x gender x contributor cell (ties broken at random), the DC class (Afore) to the rest.
	//	pre97_credit = 0: random assignment, as before.
	//	In both cases the number of DB and DC persons in each cell is target_contrT and target_contrA:
	//	  Among contributors: target_contrT -> DB (Transicion), target_contrA -> DC (Afore).
	//	  Among non-contributors: DB / DC in proportion to the contrT / contrA shares.
	//	---------------------------------------------------------------------
	generate _u2 = runiform()
	generate double _score = cond(`pre97_credit' == 1, -loa_dec, 0)
	replace  _score = 0 if missing(_score)
	sort age gender ever_contr _score _u2
	by age gender ever_contr: generate _rank = _n
	by age gender ever_contr: generate _ncell = _N

	generate _cA = round(target_contrA)
	generate _cT = round(target_contrT)

	//	Contributors: DB first (longest observed affiliation), then DC
	generate pension_class = .
	replace pension_class = 1 if ever_contr == 1 & _rank <= _cT                       // DB - Transicion
	replace pension_class = 2 if ever_contr == 1 & _rank >  _cT & _rank <= _cT + _cA // DC - Afore

	//	Non-contributors: DB / DC in proportion to the contrT share of the cell (same ordering)
	generate _db_share = target_contrT / target_contributors
	replace  _db_share = 0 if missing(_db_share)
	replace pension_class = 1 if ever_contr == 0 & _rank <= round(_ncell * _db_share)   // DB - Transicion
	replace pension_class = 2 if ever_contr == 0 & _rank >  round(_ncell * _db_share)   // DC - Afore

	label define pension_classLAB 1 "DB" 2 "DC"
	label values pension_class pension_classLAB

	drop _u2 _score _rank _ncell _cA _cT _db_share target_noncontr


	//	---------------------------------------------------------------------
	//	Step 4c-bis: Pre-1997 affiliation and service credit of the DB class
	//	  affiliation before July 1997 (months) = (age in July 1997 - age at first affiliation) x 12
	//	  service before July 1997 (months)     = affiliation x min(1, observed density x pre97_density_mult)
	//	Age is the age in the data year; July 1997 is (data_year - 1997 + 0.5) years earlier.
	//	---------------------------------------------------------------------
	generate double los_pre97 = 0
	generate double loa_pre97 = 0
	if `pre97_credit' == 1 {
		generate double _age97   = age - (`data_year' - 1997) - 0.5
		generate double _start   = cond(gender == 1,					///
				`pre97_start_min_m' + (`pre97_start_max_m' - `pre97_start_min_m') * runiform(),	///
				`pre97_start_min_f' + (`pre97_start_max_f' - `pre97_start_min_f') * runiform())
		generate double _dens    = cond(loa_dec > 0, min(los_dec / loa_dec, 1), 0)
		replace  _dens = 0 if missing(_dens)
		replace  loa_pre97 = round(12 * max(_age97 - _start, 0))			if pension_class == 1
		replace  los_pre97 = round(loa_pre97 * min(1, _dens * `pre97_density_mult'))	if pension_class == 1
		drop _age97 _start _dens
	}
	drop loa_dec los_dec


	//	---------------------------------------------------------------------
	//	Step 4d: Keep the per-individual scaling factors alongside the
	//	original id so we can apply them to the monthly data.
	//	---------------------------------------------------------------------
	keep new_id id age gender pension_class ever_contr                          ///
		 avg_wage_ind iacc_dec_ind reference_wage                              ///
		 _scale_wage _scale_iacc target_wage target_iacc los_pre97 loa_pre97      ///
		 current_affiliates current_contributors current_wage current_iacc       ///
		 target_affiliates target_contrA target_contrT target_contributors

	tempfile sampled_indiv
	save `sampled_indiv'


// =============================================================================
//	SECTION 5: EXPAND BACK TO MONTHLY STRUCTURE
// =============================================================================

	//	Join each sampled individual to their 12 monthly observations.
	//	Individuals sampled with replacement (clones) get new_id but share
	//	the original monthly record pattern.
	use `sampled_indiv', clear

	//	Bring in the monthly data via the original id
	joinby id using `monthly_full'

	//	Apply wage rescaling to monthly wages (contributors only)
	replace wage           = wage           * _scale_wage if dens == 1
	// 	Also scale up reference wages (contributors only — non-contributors were
	//	already scaled once in Section 4b; scaling here again would double-apply it)
	replace reference_wage = reference_wage * _scale_wage if ever_contr == 1
	
	// Cap reference wages to be not more than the average of the wage of working individuals for people of retirement age
	capture drop avg_wage_age
	bysort age : egen avg_wage_age   = mean(wage)
	replace reference_wage = avg_wage_age if reference_wage > avg_wage_age & age > 65
	drop avg_wage_age


	//	Non-contributors: no contributions in any month and wage must be missing
	//	(synthetic non-contributors are clones of contributors whose monthly rows carry dens = 1; without this they would
	//	be counted as contributors in the verification below, and the contrA / contrT totals would not match)
	replace dens = 0 if ever_contr == 0
	replace wage = . if dens == 0

	//	Apply iacc rescaling to every month's balance
	replace iacc = iacc * _scale_iacc
	
	drop _scale_wage _scale_iacc
	//	pension_class from sampled_indiv is broadcast to all 12 monthly rows by joinby
	//	(it was dropped from monthly_full in Section 1, so no variable conflict)
	
	// Save the weights for each sampled individual - for use in the transition rate models
	preserve
		cd "`indir'"
		keep if month ==12 
		collapse (count) weight=new_id, by(id)
		save "`weight_file'", replace
	restore
	

	//	Replace the individual id with the new synthetic id
	replace id = new_id
	drop new_id


// =============================================================================
//	SECTION 7: FINAL CLEANUP AND SAVE
// =============================================================================

	//	Drop temporary merge variables carried from aggregates
	capture drop target_affiliates target_contrA target_contrT target_contributors target_wage target_iacc
	capture drop current_affiliates current_contributors current_wage current_iacc
	
	//	Generate a weight term
	generate weight = 1 / `sample_fraction'
	
	// Cap individual accounts as a hypothetical maximum (MEXICO SPECIFIC)
	// Some people in the data have very large IACCs (about 1% of obs)
	replace iacc = min(iacc, los * reference_wage * 0.20)

	//	Add the pre-1997 affiliation and service credit (DB class only). This is done after the cap above, because the
	//	account balance only reflects the contributions since 1997.
	replace los = los + los_pre97
	replace loa = loa + loa_pre97

	//	Sort and save
	sort id month
	compress
	keep age gender id pension_class yob wage dens year month loa los iacc ///
		 spell_length wage_decile_ref wage_decile wage_decile_age_sex ///
		 status weight reference_wage los_pre97 loa_pre97
	cd "`indir'"
	save "`output_file'", replace

	display as result _n ///
		"Synthetic dataset saved to: `output_file'" _n ///
		"Observations: " _N _n ///
		"Individuals:  " _N / 12


// =============================================================================
//	SECTION 8: VERIFICATION — compare synthetic aggregates to targets
// =============================================================================

	//	Compute synthetic aggregates
	//	Wage and iacc are computed over contributors only to match how target_wage
	//	and target_iacc are defined in the admin data. Non-contributors now carry
	//	a reference wage in the wage field and iacc = 0, so including them would
	//	make synthetic means incomparable to the contributor-only targets.
	bysort id: egen _ever_contr = max(dens)
	bysort id: egen _contrA     = max(dens * (pension_class == 2))
	bysort id: egen _contrT     = max(dens * (pension_class == 1))
	generate     _wage_contr    = wage if dens == 1
	bysort id: egen _avg_wage   = mean(_wage_contr)
	bysort id: egen _iacc_dec   = max(iacc * (month == 12))   // December balance regardless of dens
	replace      _iacc_dec      = . if _ever_contr == 0        // exclude non-contributors from mean
	drop _wage_contr
	keep if month == 12

	//	Pre-1997 credit: only DB-class persons have one, and the DB / DC counts above are unchanged
	assert los_pre97 == 0 & loa_pre97 == 0 if pension_class == 2
	display as result _n "=== PRE-1997 SERVICE CREDIT (years), DB-class persons by age group ==="
	preserve
		keep if pension_class == 1
		generate agegrp = recode(age, 29, 39, 49, 54, 59, 64, 120)
		generate credit_yrs = los_pre97 / 12
		generate loa_pre_yrs = loa_pre97 / 12
		tabstat credit_yrs loa_pre_yrs, by(agegrp) statistics(n mean p50 p90) columns(statistics)
	restore

	collapse (count) synthetic_affiliates = id           ///
			 (sum)   synthetic_contrA     = _contrA      ///
			 (sum)   synthetic_contrT     = _contrT      ///
			 (mean)  synthetic_wage       = _avg_wage    ///
			 (mean)  synthetic_iacc       = _iacc_dec,   ///
			 by(age gender)

	//	Merge back the targets for comparison
	merge 1:1 age gender using `targets', keep(match master) nogenerate

	//	Display differences as % of target
	generate diff_aff_pct    = 100 * (synthetic_affiliates - target_affiliates) / target_affiliates
	generate diff_contrA_pct = 100 * (synthetic_contrA     - target_contrA)     / target_contrA
	generate diff_contrT_pct = 100 * (synthetic_contrT     - target_contrT)     / target_contrT
	generate diff_wage_pct   = 100 * (synthetic_wage       - target_wage)       / target_wage
	generate diff_iacc_pct   = 100 * (synthetic_iacc       - target_iacc)       / target_iacc

	display as result _n "=== VERIFICATION: mean absolute % deviation from targets ==="
	summarize diff_aff_pct diff_contrA_pct diff_contrT_pct diff_wage_pct diff_iacc_pct, format

	//	Flag cells with >1% deviation
	list age gender diff_aff_pct diff_contrA_pct diff_contrT_pct diff_wage_pct diff_iacc_pct ///
		if abs(diff_wage_pct) > 1 | abs(diff_iacc_pct) > 1, noobs
