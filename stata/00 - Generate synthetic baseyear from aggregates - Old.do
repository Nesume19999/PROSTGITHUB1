/*******************************************************************************
Title:			Generate Synthetic Baseyear Dataset from Aggregate Targets
Author:			Duncan MacDonald
Description:	Samples individuals from baseyear microdata and rescales wages
				and individual account balances so that cell-level statistics
				(by age × gender) match the target aggregates:
				  - Number of affiliates       (numA)
				  - contrA contributors (Afore / DC) by age × gender
				  - contrT contributors (Transición / DB) by age × gender
				  - Average monthly wage       (wage)
				  - Average individual account (iacc)

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

	//	Random seed for reproducibility
	local seed = 12345
	
	// File locations
	local indir 		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"	// User inputs

	//	File paths
	local baseyear_file   "baseyear_data_MEX.dta"
	local aggregates_file "001-Data Aggregates.dta"
	local output_file     "synthetic_baseyear_10pct_sample.dta"

	//	Create output folder if needed
	capture mkdir "Output"

	set seed `seed'


// =============================================================================
//	SECTION 1: BUILD INDIVIDUAL-LEVEL POOL FROM BASEYEAR
// =============================================================================

	cd "`indir'"
	use "`baseyear_file'", clear

	//	Wage is only defined when contributing
	*generate _wage_contr = wage if dens == 1

	//	Individual-level summaries (constant within person)
	bysort id: egen ever_contr   = max(dens)        // 1 if contributed any month
	bysort id: egen avg_wage_ind = mean(wage)  		// mean wage while contributing
	bysort id: egen iacc_dec_ind = max(iacc * (month == 12))  // December balance

	*drop _wage_contr

	//	Drop afore from the monthly file — the synthetically assigned value
	//	from sampled_indiv will be broadcast to all 12 rows via joinby
	capture drop afore

	//	Save full monthly data (we will join back to this later)
	sort id month
	tempfile monthly_full
	save `monthly_full'

	//	Keep the afore indicator (1 = Afore/DC, 0 = Transición/DB) if it exists
	//	in the source data; otherwise create a placeholder (assigned in step 4c)
	capture confirm variable afore
	if _rc != 0 generate afore = .

	//	One observation per individual for the sampling step
	keep if month == 12
	keep id age gender afore ever_contr avg_wage_ind iacc_dec_ind

	tempfile indiv_pool
	save `indiv_pool'
	
// =============================================================================
//	SECTION 2: COMPUTE CURRENT CELL STATISTICS FROM BASEYEAR
// =============================================================================

	//	Current counts and means by cell
	generate _contrA = (ever_contr == 1 & afore == 1)
	generate _contrT = (ever_contr == 1 & afore == 0)

	collapse (count) current_affiliates = id             ///
			 (sum)   current_contrA     = _contrA        ///
			 (sum)   current_contrT     = _contrT        ///
			 (mean)  current_wage       = avg_wage_ind   ///
			 (mean)  current_iacc       = iacc_dec_ind,  ///
			 by(age gender)

	*drop _contrA _contrT

	tempfile cur_agg
	save `cur_agg'



// =============================================================================
//	SECTION 3: LOAD TARGET AGGREGATES
// =============================================================================

	cd "`indir'"
	use "`aggregates_file'", clear

	//	Keep contrA and contrT separately so we can match each independently
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
		//	Ensure the two contributor groups don't exceed total affiliates
		replace target_contrA = min(target_contrA, target_affiliates)
		replace target_contrT = min(target_contrT, target_affiliates - target_contrA)
	}

	//	Convenience total used in step 4c
	generate target_contributors = target_contrA + target_contrT

	tempfile targets
	save `targets'




// =============================================================================
//	SECTION 4: SAMPLE INDIVIDUALS TO MATCH TARGET AFFILIATE COUNTS
// =============================================================================

	use `indiv_pool', clear

	//	Attach targets and current aggregates to every individual in the pool
	merge m:1 age gender using `targets', keep(match) nogenerate
	merge m:1 age gender using `cur_agg', keep(match) nogenerate

	//	---------------------------------------------------------------------
	//	Step 4a: Sample individuals within each cell.
	//	First randomly shuffle the pool and sample down to the target (handles
	//	cells where target < current).  Then expand the survivors so each cell
	//	reaches the target (handles cells where target > current). A final trim
	//	cuts any surplus created by integer rounding in expand.
	//	---------------------------------------------------------------------

	//	(1) Random shuffle + sample down where target < current
	generate _u = runiform()
	sort age gender _u
	by age gender: keep if _n <= target_affiliates

	//	(2) Expand up where target > current (cell_n = survivors after step 1)
	bysort age gender: generate _cell_n = _N
	generate _rep = ceil(target_affiliates / _cell_n)
	replace  _rep = max(_rep, 1)
	expand   _rep
	drop     _rep _cell_n

	//	(3) Final trim to exactly target_affiliates per cell
	sort age gender _u
	by age gender: keep if _n <= target_affiliates
	drop _u

	//	Assign a new unique individual ID for the synthetic dataset
	generate new_id = _n


	//	---------------------------------------------------------------------
	//	Step 4b: Compute per-cell means after sampling, then derive per-
	//	individual rescaling factors for wage and iacc.
	//	---------------------------------------------------------------------
	bysort age gender: egen _samp_wage = mean(avg_wage_ind)
	bysort age gender: egen _samp_iacc = mean(iacc_dec_ind)

	//	Multiplicative factor so that cell mean equals target
	generate _scale_wage = cond(_samp_wage > 0 & !missing(_samp_wage), target_wage / _samp_wage, 1)
	generate _scale_iacc = cond(_samp_iacc > 0 & !missing(_samp_iacc), target_iacc / _samp_iacc, 1)

	replace avg_wage_ind = avg_wage_ind * _scale_wage
	replace iacc_dec_ind = iacc_dec_ind * _scale_iacc

	drop _samp_wage _samp_iacc


	//	---------------------------------------------------------------------
	//	Step 4c: Assign contributor status and afore/transicion type to match
	//	target contrA (Afore/DC) and contrT (Transición/DB) counts.
	//
	//	Random ranking within each cell determines who gets which status:
	//	  ranks 1 … target_contrA                → contributor, afore = 1
	//	  ranks target_contrA+1 … total_contr    → contributor, afore = 0
	//	  remaining                               → non-contributor;
	//	                                            afore assigned at random
	//	                                            using the contrA share
	//	---------------------------------------------------------------------
	generate _u2 = runiform()
	sort age gender _u2
	by age gender: generate _rank = _n

	local cA "_contrA_int"
	local cT "_contrT_int"
	generate `cA' = round(target_contrA)
	generate `cT' = round(target_contrT)

	//	Contributor + afore assignment
	replace ever_contr = (_rank <= `cA' + `cT')
	replace afore      = 1 if _rank <= `cA'
	replace afore      = 0 if _rank > `cA' & _rank <= `cA' + `cT'

	//	Non-contributors: assign afore randomly proportional to contrA share
	generate _afore_share = target_contrA / target_contributors
	replace  afore = (_u2 < _afore_share) ///
					 if _rank > `cA' + `cT'

	drop _u2 _rank `cA' `cT' _afore_share


	//	---------------------------------------------------------------------
	//	Step 4d: Keep the per-individual scaling factors alongside the
	//	original id so we can apply them to the monthly data.
	//	---------------------------------------------------------------------
	keep new_id id age gender afore ever_contr avg_wage_ind iacc_dec_ind ///
		 _scale_wage _scale_iacc target_wage target_iacc ///
		 current_affiliates current_contrA current_contrT current_wage current_iacc ///
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

	//	Apply wage rescaling to monthly wages (when contributing)
	replace wage = wage * _scale_wage if dens == 1

	//	Apply iacc rescaling to every month's balance
	replace iacc = iacc * _scale_iacc

	//	Reconcile monthly dens with the (possibly adjusted) ever_contr flag:
	//	  - If the individual was promoted to contributor, set dens=1 all year
	//	    and assign the (rescaled) individual average wage to each month.
	//	  - If demoted to non-contributor, set dens=0 and wage=. all year.

	//	Identify status changes
	bysort new_id: egen _orig_ever_contr = max(dens)  // pre-adjustment status

	//	Promoted: was non-contributor, now contributor
	replace dens = 1       if ever_contr == 1 & _orig_ever_contr == 0
	replace wage = avg_wage_ind ///
					if ever_contr == 1 & _orig_ever_contr == 0

	//	Demoted: was contributor, now non-contributor
	replace dens = 0       if ever_contr == 0 & _orig_ever_contr == 1
	replace wage = .       if ever_contr == 0 & _orig_ever_contr == 1

	drop _orig_ever_contr _scale_wage _scale_iacc
	//	Note: afore was dropped from monthly_full in Section 1, so the value
	//	from sampled_indiv (assigned in step 4c) is already present in every
	//	monthly row after the joinby — no further action needed here.

	//	Replace the individual id with the new synthetic id
	replace id = new_id
	drop new_id


// =============================================================================
//	SECTION 7: FINAL CLEANUP AND SAVE
// =============================================================================

	//	Drop temporary merge variables carried from aggregates
	capture drop target_affiliates target_contrA target_contrT target_contributors target_wage target_iacc
	capture drop current_affiliates current_contrA current_contrT current_wage current_iacc

	//	Sort and save
	sort id month
	compress
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
	bysort id: egen _ever_contr = max(dens)
	bysort id: egen _contrA     = max(dens * (afore == 1))   // DC contributor
	bysort id: egen _contrT     = max(dens * (afore == 0))   // DB contributor
	bysort id: egen _avg_wage   = mean(wage)
	bysort id: egen _iacc_dec   = max(iacc * (month == 12))
	keep if month == 12

	collapse (count) synthetic_affiliates = id             ///
			 (sum)   synthetic_contrA     = _contrA        ///
			 (sum)   synthetic_contrT     = _contrT        ///
			 (mean)  synthetic_wage       = _avg_wage      ///
			 (mean)  synthetic_iacc       = _iacc_dec,     ///
			 by(age gender)

	generate synthetic_contributors = synthetic_contrA + synthetic_contrT

	//	Merge back the targets for comparison
	merge 1:1 age gender using `targets', keep(match master) nogenerate

	//	Display differences as % of target
	generate diff_aff_pct   = 100 * (synthetic_affiliates - target_affiliates)   / target_affiliates
	generate diff_contrA_pct= 100 * (synthetic_contrA     - target_contrA)       / target_contrA
	generate diff_contrT_pct= 100 * (synthetic_contrT     - target_contrT)       / target_contrT
	generate diff_wage_pct  = 100 * (synthetic_wage       - target_wage)         / target_wage
	generate diff_iacc_pct  = 100 * (synthetic_iacc       - target_iacc)         / target_iacc

	display as result _n "=== VERIFICATION: mean absolute % deviation from targets ==="
	summarize diff_aff_pct diff_contrA_pct diff_contrT_pct diff_wage_pct diff_iacc_pct, format

	//	Flag cells with >1% deviation
	list age gender diff_aff_pct diff_contrA_pct diff_contrT_pct diff_wage_pct diff_iacc_pct ///
		if abs(diff_wage_pct) > 1 | abs(diff_iacc_pct) > 1, noobs
