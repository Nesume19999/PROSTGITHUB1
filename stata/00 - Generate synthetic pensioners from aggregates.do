/*******************************************************************************
Title:			Generate Synthetic Pensioner Dataset from Aggregate Targets
Author:			Duncan MacDonald
Description:	Samples individuals from pensioner microdata and rescales
				pension benefits so that cell-level statistics
				(by age × gender × pension type) match the target aggregates:
				  - Number of beneficiaries  (numB–numG)
				  - Average monthly benefit  (penB–penG)
				for all six pension types:
				  1 = Old-age DB   (B)     4 = Old-age DC   (E)
				  2 = Disability DB(C)     5 = Disability DC(F)
				  3 = Survivor DB  (D)     6 = Survivor DC  (G)

Inputs:
  Input/pensioners_MEX.dta        - Individual pensioner microdata
  Input/001-Data Aggregates.dta   - Target aggregates by age × gender

Output:
  Output/synthetic_pensioners_Xpct_sample.dta

Requires: gtools  (ssc install gtools)
*******************************************************************************/

//	INITIALIZATION
	clear all
	pause on
	set trace off


// =============================================================================
//	SECTION 0: USER PARAMETERS  ← edit here
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
	//	rebase = 1: pension benefits are moved from `data_year' to `base_year' with the cumulative growth rates in `wage_growth_file'
	//	            (wage_growth = nominal wage growth, cpi = inflation, both in %). 0 = leave the values in `data_year' pesos.
	local rebase           = 1
	local data_year        = 2020
	local base_year        = 2024
	local country          = "MEX"
	local wage_growth_file = "wage_growth_`country'.csv"

	//	File locations
	local indir = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"

	//	File paths
	local pensioners_file  "pensioners_MEX.dta"
	local aggregates_file  "001-Data Aggregates.dta"
	local output_file      "synthetic_pensioners_`sample_name'pct_sample.dta"

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
//	SECTION 1: BUILD INDIVIDUAL-LEVEL POOL FROM PENSIONER MICRODATA
// =============================================================================

	cd "`indir'"
	use "`pensioners_file'", clear

	//	Ensure pension_id exists (1–6 mapping to types B–G)
	capture confirm variable pension_id
	if _rc != 0 {
		generate pension_id = .
		replace  pension_id = 1 if inlist(type, "B")
		replace  pension_id = 2 if inlist(type, "C")
		replace  pension_id = 3 if inlist(type, "D")
		replace  pension_id = 4 if inlist(type, "E")
		replace  pension_id = 5 if inlist(type, "F")
		replace  pension_id = 6 if inlist(type, "G")
	}
	
	generate id = _n

	keep id age gender pension_id pension_benefit startyear pension_class pension_type
	drop if missing(pension_id)

	tempfile indiv_pool
	save `indiv_pool'


// =============================================================================
//	SECTION 2: COMPUTE CURRENT CELL STATISTICS FROM PENSIONER DATA
// =============================================================================

	collapse (count) current_num = id              ///
			 (mean)  current_pen = pension_benefit, ///
			 by(age gender pension_id)

	tempfile cur_agg
	save `cur_agg'


// =============================================================================
//	SECTION 3: LOAD AND RESHAPE TARGET AGGREGATES
// =============================================================================

	cd "`indir'"
	use "`aggregates_file'", clear

	//	Rename benefit-type variables to numeric suffix for reshape
	//	B=1 (DB old-age), C=2 (DB disability), D=3 (DB survivor)
	//	E=4 (DC old-age), F=5 (DC disability), G=6 (DC survivor)
	rename (numB penB numC penC numD penD numE penE numF penF numG penG) ///
		   (num1 pen1 num2 pen2 num3 pen3 num4 pen4 num5 pen5 num6 pen6)

	keep age gender num1 pen1 num2 pen2 num3 pen3 num4 pen4 num5 pen5 num6 pen6

	//	Reshape to long: one row per (age, gender, pension_id)
	reshape long num pen, i(age gender) j(pension_id)

	rename (num pen) (target_num target_pen)

	//	Rebase benefits in payment to the base year (pensions in payment are indexed with prices)
	replace target_pen = target_pen * `cpi_index'

	//	Drop cells with no target beneficiaries
	drop if missing(target_num) | target_num == 0

	//	Apply sample fraction up-front
	if `sample_fraction' < 1 {
		replace target_num = max(1, round(target_num * `sample_fraction'))
	}

	tempfile targets
	save `targets'


// =============================================================================
//	SECTION 3b: AUGMENT POOL FOR TARGET CELLS MISSING FROM PENSIONER DATA
// =============================================================================
//	Some target cells have no observations in the pensioner microdata.
//	For each such cell we find the nearest available age within the same
//	gender and pension type and copy those individuals, re-labelling them
//	with the target age. Falls back to opposite gender if necessary.

	//	Record which cells exist in the pool
	use `indiv_pool', clear
	keep age gender pension_id
	duplicates drop
	tempfile pool_cells
	save `pool_cells'

	//	Identify target cells absent from the pool
	use `targets', clear
	merge 1:1 age gender pension_id using `pool_cells', keep(master) nogenerate
	keep age gender pension_id
	count
	local n_missing = r(N)

	if `n_missing' > 0 {

		rename age target_age

		//	--- Pass 1: nearest age, same gender and pension type ---
		joinby gender pension_id using `pool_cells'
		generate _diff = abs(target_age - age)
		bysort target_age gender pension_id (_diff age): keep if _n == 1
		rename age donor_age
		tempfile donor_same
		save `donor_same'

		//	--- Pass 2: fallback when no same-gender data exists for a type ---
		use `targets', clear
		merge 1:1 age gender pension_id using `pool_cells', keep(master) nogenerate
		keep age gender pension_id
		rename age target_age
		merge 1:1 target_age gender pension_id using `donor_same', keep(master) nogenerate
		count
		if r(N) > 0 {
			preserve
				use `pool_cells', clear
				rename (age gender) (donor_age donor_gender)
				tempfile pool_all
				save `pool_all'
			restore
			cross using `pool_all'
			keep if pension_id == donor_gender  // keep same pension type
			generate _diff = abs(target_age - donor_age)
			bysort target_age gender pension_id (_diff donor_age): keep if _n == 1
			drop _diff donor_gender
			append using `donor_same'
			save `donor_same', replace
		} // end if r(N) > 0

		//	--- Pull donor individuals and re-label with target age ---
		use `donor_same', clear
		rename donor_age age
		joinby age gender pension_id using `indiv_pool'

		drop age
		rename target_age age

		append using `indiv_pool'
		save `indiv_pool', replace
	} // end if n_missing 


// =============================================================================
//	SECTION 4: SAMPLE AND RESCALE BY (AGE × GENDER × PENSION TYPE) CELL
// =============================================================================

	use `indiv_pool', clear

	//	Attach targets and current aggregates
	merge m:1 age gender pension_id using `targets',  keep(match) nogenerate
	merge m:1 age gender pension_id using `cur_agg',  keep(match master) nogenerate

	//	---------------------------------------------------------------------
	//	Step 4a: Sample within each cell.
	//	Shuffle + sample down (target < current), then expand + trim (target > current).
	//	---------------------------------------------------------------------

	//	(1) Random shuffle + sample down
	generate _u = runiform()
	sort age gender pension_id _u
	by age gender pension_id: keep if _n <= target_num

	//	(2) Expand up where target > current
	bysort age gender pension_id: generate _cell_n = _N
	generate _rep = ceil(target_num / _cell_n)
	replace  _rep = max(_rep, 1)
	expand   _rep
	drop     _rep _cell_n

	//	(3) Final trim to exactly target_num per cell
	sort age gender pension_id _u
	by age gender pension_id: keep if _n <= target_num
	drop _u

	//	Assign a new unique individual ID
	generate new_id = _n


	//	---------------------------------------------------------------------
	//	Step 4b: Rescale pension benefits so each cell mean matches target.
	//	  scaled_benefit_i = benefit_i × (target_pen / sample_mean_pen)
	//	Cell mean = target  ✓   |   Relative dispersion unchanged  ✓
	//	---------------------------------------------------------------------
	bysort age gender pension_id: egen _samp_pen = mean(pension_benefit)

	generate _scale_pen = target_pen / _samp_pen
	replace  pension_benefit = pension_benefit * _scale_pen

	drop _samp_pen _scale_pen


// =============================================================================
//	SECTION 5: FINAL CLEANUP AND SAVE
// =============================================================================

	//	Replace original id with new synthetic id
	replace id = new_id
	drop new_id

	//	Drop temporary merge variables
	capture drop target_num target_pen current_num current_pen
	
	//	Generate a weight term
	generate weight = 1 / `sample_fraction'

	sort pension_id age gender id
	compress

	cd "`indir'"
	keep age gender pension_id pension_benefit id startyear pension_class pension_type weight
	save "`output_file'", replace

	display as result _n ///
		"Synthetic pensioner dataset saved to: `output_file'" _n ///
		"Observations: " _N


// =============================================================================
//	SECTION 6: VERIFICATION — compare synthetic aggregates to targets
// =============================================================================

	collapse (count) synthetic_num = id              ///
			 (mean)  synthetic_pen = pension_benefit, ///
			 by(age gender pension_id)

	//	Merge back targets for comparison
	merge 1:1 age gender pension_id using `targets', keep(match master) nogenerate

	//	Label pension types for readability
	capture label drop pension_id_LAB
	label define pension_id_LAB ///
		1 "Old-age DB"    2 "Disability DB" 3 "Survivor DB" ///
		4 "Old-age DC"    5 "Disability DC" 6 "Survivor DC"
	label values pension_id pension_id_LAB

	//	Differences as % of target
	generate diff_num_pct = 100 * (synthetic_num - target_num) / target_num
	generate diff_pen_pct = 100 * (synthetic_pen - target_pen) / target_pen

	display as result _n "=== VERIFICATION: mean absolute % deviation from targets ==="
	bysort pension_id: summarize diff_num_pct diff_pen_pct, format

	//	Flag cells with >1% deviation in benefit mean
	list pension_id age gender diff_num_pct diff_pen_pct ///
		if abs(diff_pen_pct) > 1, noobs
