/*******************************************************************************
Title: 			Generate the wage distribution by decile (decile_wages_MEX.csv)
Author: 		Duncan MacDonald
Description:	For building PROST v2 pension model.
				Takes the base-year affiliate microdata (baseyear_data_MEX.dta, made by
				"01 - Pre-processing - Generate baseyear dataset.do") and computes the mean,
				standard deviation, minimum and maximum of the monthly wage of each wage
				decile (formal workers in the last year of the data).
				The wages of the microdata are in the prices of the year of the data (`data_year').
				With rebase = 1 the statistics are moved to the base year of the projection
				(`base_year') with the cumulative nominal wage growth in wage_growth_MEX.csv,
				the same index used by the synthetic data generators ("00 - Generate synthetic ...").

Inputs:
	Input/baseyear_data_MEX.dta
	Input/wage_growth_MEX.csv

Output:
	Input/decile_wages_MEX.csv		(columns: year, wage_decile, mean, sd, max, min; year = base year if rebased)

Requires: gtools (ssc install gtools)
*******************************************************************************/

//	INITIALIZATION
	clear all
	pause off
	set trace off

//	SET PARAMETERS
	local country          = "MEX"
	local indir            = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local baseyear_file    = "baseyear_data_`country'.dta"
	local wage_growth_file = "wage_growth_`country'.csv"
	local output_file      = "decile_wages_`country'.csv"

//	Rebasing from the year of the data to the base year of the projection (0 = keep the prices of the data year)
	local rebase    = 1
	local data_year = 2020
	local base_year = 2024

********************************************************************************
//	REBASING INDEX: cumulative nominal wage growth between the data year and the base year
	local wage_index = 1
	if `rebase' == 1 {
		import delimited "`indir'/`wage_growth_file'", clear
		keep if iso3 == "`country'" & inrange(year, `data_year' + 1, `base_year')
		assert _N == `base_year' - `data_year'
		generate double ln_w = ln(1 + wage_growth / 100)
		quietly summarize ln_w
		local wage_index = exp(r(sum))
		display as result "Rebasing `data_year' to `base_year': wage index = " %6.4f `wage_index'
		clear
	}

********************************************************************************
//	WAGE STATISTICS BY DECILE
	cd "`indir'"
	use "`baseyear_file'", clear

//	Check that the microdata are for the expected year
	quietly summarize year
	assert r(max) == `data_year'

//	Formal workers with a wage and a wage decile
	keep if dens > 0 & !missing(wage) & wage_decile > 0

	collapse (mean) mean=wage (sd) sd=wage (max) max=wage (min) min=wage, by(year wage_decile)

//	Move to the base year
	foreach v in mean sd max min {
		replace `v' = `v' * `wage_index'
	}
	replace year = `base_year' if `rebase' == 1

	list, noobs
	export delimited "`output_file'", replace
	display as result "Saved `output_file' (wages in `=cond(`rebase' == 1, `base_year', `data_year')' pesos per month)"
