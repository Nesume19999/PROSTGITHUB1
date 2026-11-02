/*******************************************************************************
Title: 			PROST v2 - Output charts
Author: 		Duncan MacDonald
Description:	Builds the standard charts of a projection run, and writes the data behind
				every chart to Excel. It is called at the end of the projection script when
				the toggle  output_charts = 1  is set ("1 - PROSTv2 - Build projection
				database - ANNUAL DATA VERY LOW.do"), but it can also be run on its own on the
				files of an earlier run:

					do "1b - PROSTv2 - Output charts.do" "<outdir>" "<simname>" "<chartdir>" ///
						"<gdp csv or empty>" "<label DB system>" "<label DC system>" "<years>" ///
						"<real GDP growth, percent>" "<wage growth csv with the column cpi>"

				outdir    : folder with the projection outputs (the Inyear-...-Totals.csv files)
				simname   : name of the simulation
				chartdir  : folder where the chart data of the run (chart_stock.dta, chart_newret.dta,
				            saved by the projection) are, and where the graphs and Excel files go
				gdp csv   : optional file with columns  year, gdp  (nominal GDP in local currency, per year,
				            same currency as the pension payments). Without it the two GDP charts are skipped.
				labels    : names of the DB and the DC system in the charts (default Law 73 and Law 97)
				years     : years of the age-distribution charts (default: first, middle and last year)
				real GDP growth : annual real growth (percent, default 2) used for the years after the last year of the GDP file
				wage growth csv : the wage growth input file of the model, with the assumed inflation by year (column cpi, percent; the last year is carried forward)
				            Beyond the last year of the GDP file, nominal GDP grows by (1 + real growth) x (1 + inflation) - 1 each year.

				Each chart is saved as NN_name.png and NN_name.gph, with the data used to draw it in
				NN_name.xlsx.

				Charts:
				 01  Affiliates, active affiliates and pensioners; active affiliates as a share of the working-age population
				 02  Old-age pensions in payment by system, and their distribution by age and gender in selected years
				 03  Average old-age pension in payment by system
				 04  Age distribution of new retirees by system, all and at the minimum pension
				 05  Share of new retirees at the minimum pension: by wage decile, and by age and gender
				 06  Total pension payments by system and year
				 07  Old-age pension expenditure by component, share of GDP
				 08  Government top-up per recipient by wage quintile and gender
				 09  Share receiving a top-up and average size, by wage decile at retirement
				 10  Share retiring with a lump sum, by wage decile and year
				 11  Retirement outcomes by wage decile: lump sum, replacement rate, income adequacy, lifetime pension
				 12  Total old-age pension spending, share of GDP
				 13  Average replacement rate by year, and by pension class

Notes:
	- Pensioners of the base year have no top-up, wage decile or lump-sum information, so the charts that
	  use these variables (05, 08-11, and the top-up part of 07) describe the pensioners who retire in the projection.
	- Weights are applied everywhere: counts are numbers of people, money is in current local currency.
*******************************************************************************/

args outdir simname chartdir gdpfile lab_db lab_dc distyears realg indexfile   // indexfile = wage growth csv (column cpi)

if "`realg'" == "" local realg = 2
if "`lab_db'" == "" local lab_db = "Law 73"
if "`lab_dc'" == "" local lab_dc = "Law 97"

//	Palette of the presentation
local navy   = "31 53 87"
local steel  = "108 141 176"
local lsteel = "170 187 214"
local maroon = "123 58 75"
local rose   = "190 146 160"
local grey   = "156 160 168"

global cx_dir = "`chartdir'"
capture mkdir "`chartdir'"

//	Common graph options
local gcommon = `"graphregion(color(white) margin(small)) plotregion(color(white) lcolor(white)) yscale(range(0))"'
local ycommon = `"ylabel(#6, angle(0) grid glcolor(gs14) labsize(small)) xlabel(, labsize(small) nogrid)"'

capture program drop cx_labels
program define cx_labels
	label define cx_sys 1 "$cx_lab_db" 2 "$cx_lab_dc", replace
	label define cx_gen 1 "Men" 2 "Women", replace
end

capture program drop cx_save
program define cx_save
	args name
	graph export "$cx_dir/`name'.png", width(1800) replace
	graph save   "$cx_dir/`name'.gph", replace
end

capture program drop cx_xlsx
program define cx_xlsx
	args name sheet
	export excel using "$cx_dir/`name'.xlsx", sheet("`sheet'", replace) firstrow(variables)
end

********************************************************************************
//	LOAD THE DATA
tempfile stock newret aff gdp

use "`chartdir'/chart_stock.dta", clear
quietly summarize year
local y0 = r(min)
local y1 = r(max)
save `stock'

use "`chartdir'/chart_newret.dta", clear
save `newret'

import delimited "`outdir'/1_PROSTv2-`simname'-Inyear-Affiliate-Reporting-Totals.csv", clear
keep year num_affiliates num_contributors population_total working_age_total
save `aff'

local has_gdp = 0
if "`gdpfile'" != "" {
	capture import delimited "`gdpfile'", clear
	if _rc == 0 {
		//	IMF WEO file of Input/Defaults/gdp (gdp_lcu_billions: current prices, billions of local currency) or a file with the columns year and gdp (local currency)
		capture confirm variable gdp_lcu_billions
		if _rc == 0 generate double gdp = gdp_lcu_billions * 1e9
		capture confirm variable year gdp
		if _rc == 0 {
			keep year gdp
			drop if missing(gdp)
			//	Years after the last year of the file: nominal GDP grows by (1 + real growth) x (1 + inflation) - 1 a year,
			//	with the real growth assumption realg (percent) and the inflation assumption of the model (cpi of the wage growth input file, by year)
			quietly summarize year
			local gy1 = r(max)
			if `gy1' < `y1' {
				tempfile infl
				preserve
					clear
					capture import delimited "`indexfile'", clear
					if _rc == 0 {
						keep year cpi
						rename cpi pindex_inflation
						save `infl'
						local has_infl = 1
					}
					else local has_infl = 0
				restore
				quietly summarize gdp if year == `gy1'
				local g_last = r(mean)
				local n0 = _N
				quietly set obs `=`n0' + `y1' - `gy1''
				quietly replace year = `gy1' + (_n - `n0') if _n > `n0'
				generate double inflation_pct = 0
				if `has_infl' == 1 {
					merge 1:1 year using `infl', keep(1 3) nogenerate
					sort year
					//	years after the last year of the wage growth file use its last value
					quietly summarize year if !missing(pindex_inflation)
					local iy1 = r(max)
					quietly summarize pindex_inflation if year == `iy1'
					quietly replace pindex_inflation = r(mean) if missing(pindex_inflation) & year > `iy1'
					quietly replace inflation_pct = pindex_inflation if !missing(pindex_inflation)
					drop pindex_inflation
				}
				else display as error "Wage growth file `indexfile' not found: GDP after `gy1' grows with the real growth assumption only (inflation = 0)"
				sort year
				forvalues i = `=`n0' + 1'/`=_N' {
					quietly replace gdp = gdp[`i' - 1] * (1 + `realg' / 100) * (1 + inflation_pct[`i'] / 100) in `i'
				}
				drop inflation_pct
				display as text "GDP after `gy1' extended with real growth of `realg'% a year plus the inflation assumption (`y1' value: " %14.0fc gdp[_N] ")"
			}
			save `gdp'
			local has_gdp = 1
		}
	}
	if `has_gdp' == 0 display as error "GDP file `gdpfile' not found or without the columns year and gdp: the GDP charts (07, 12) are skipped"
}
else display as error "No GDP file given: the GDP charts (07, 12) are skipped"

//	Years of the age-distribution charts
if "`distyears'" == "" {
	local ymid = round((`y0' + `y1') / 2)
	local distyears = "`y0' `ymid' `y1'"
	local distyears : list uniq distyears
}

//	Names of the systems
global cx_lab_db = "`lab_db'"
global cx_lab_dc = "`lab_dc'"


********************************************************************************
//	01  AFFILIATES, ACTIVE AFFILIATES AND PENSIONERS
use `stock', clear
collapse (sum) pensioners=n, by(year)
tempfile pt
save `pt'
use `aff', clear
merge 1:1 year using `pt', nogenerate keep(1 3)
generate affiliates_millions        = num_affiliates / 1e6
generate active_affiliates_millions = num_contributors / 1e6
generate pensioners_millions        = pensioners / 1e6
generate active_pct_working_age     = 100 * num_contributors / working_age_total
keep year affiliates_millions active_affiliates_millions pensioners_millions active_pct_working_age
sort year
cx_xlsx 01_affiliates_and_pensioners data
twoway 	(line affiliates_millions year, lcolor("`navy'") lwidth(medthick))					///
		(line active_affiliates_millions year, lcolor("`maroon'") lwidth(medthick) lpattern(dash))	///
		(line pensioners_millions year, lcolor("`steel'") lwidth(medthick)),				///
		title("Affiliates, active affiliates and pensioners", size(medlarge) color("`navy'"))	///
		ytitle("Millions") xtitle("Year") `ycommon' `gcommon'							///
		legend(order(1 "Affiliates" 2 "Active affiliates (contributing)" 3 "Pensioners") rows(1) position(6) size(small))
cx_save 01_affiliates_and_pensioners
twoway 	(line active_pct_working_age year, lcolor("`maroon'") lwidth(medthick) lpattern(dash)),	///
		title("Active affiliates, share of the working-age population", size(medlarge) color("`navy'"))	///
		ytitle("Percent of working-age population") xtitle("Year") `ycommon' `gcommon' legend(off)
cx_save 01b_active_affiliate_coverage


********************************************************************************
//	02  OLD-AGE PENSIONS IN PAYMENT BY SYSTEM
use `stock', clear
keep if pension_type == 1
collapse (sum) pensions_in_payment=n_pay, by(year pension_class)
fillin year pension_class
replace pensions_in_payment = 0 if missing(pensions_in_payment)
drop _fillin
generate pensions_millions = pensions_in_payment / 1e6
cx_labels
label values pension_class cx_sys
decode pension_class, generate(system)
cx_xlsx 02_oldage_pensions_by_system data
reshape wide pensions_in_payment pensions_millions system, i(year) j(pension_class)
twoway 	(line pensions_millions1 year, lcolor("`steel'") lwidth(medthick))		///
		(line pensions_millions2 year, lcolor("`navy'") lwidth(medthick)),		///
		title("Old-age pensions in payment, by system", size(medlarge) color("`navy'"))	///
		ytitle("Millions of pensions in payment") xtitle("Year") `ycommon' `gcommon'	///
		legend(order(1 "`lab_db'" 2 "`lab_dc'") rows(1) position(6) size(small))
cx_save 02_oldage_pensions_by_system

//	Distribution by age and gender in selected years
local allyears_data = ""
tempfile dist_all
local first = 1
foreach y of local distyears {
	use `stock', clear
	keep if pension_type == 1 & year == `y'
	collapse (sum) pensions=n_pay, by(pension_class gender age)
	replace pensions = pensions / 1000
	generate year = `y'
	if `first' == 1 {
		save `dist_all', replace
		local first = 0
	}
	else {
		append using `dist_all'
		save `dist_all', replace
	}
}
use `dist_all', clear
cx_labels
label values pension_class cx_sys
label values gender cx_gen
decode pension_class, generate(system)
decode gender, generate(gender_name)
rename pensions pensions_thousands
cx_xlsx 02b_oldage_pensions_by_age data
rename pensions_thousands pensions
foreach y of local distyears {
	preserve
		keep if year == `y'
		keep year gender age pension_class pensions
		reshape wide pensions, i(year gender age) j(pension_class)
		foreach v in pensions1 pensions2 {
			capture confirm variable `v'
			if _rc generate `v' = 0
		}
		generate age_a = age - 0.2
		generate age_b = age + 0.2
		twoway 	(bar pensions1 age_a if gender == 1, barwidth(0.4) color("`steel'"))	///
				(bar pensions2 age_b if gender == 1, barwidth(0.4) color("`navy'")),	///
				title("Men", size(medsmall) color("`navy'") position(11)) ytitle("Thousands") xtitle("Age in `y'") `ycommon' `gcommon'	///
				legend(order(1 "`lab_db'" 2 "`lab_dc'") rows(1) position(6) size(small)) name(cx_m, replace) nodraw
		twoway 	(bar pensions1 age_a if gender == 2, barwidth(0.4) color("`steel'"))	///
				(bar pensions2 age_b if gender == 2, barwidth(0.4) color("`navy'")),	///
				title("Women", size(medsmall) color("`navy'") position(11)) ytitle("Thousands") xtitle("Age in `y'") `ycommon' `gcommon'	///
				legend(order(1 "`lab_db'" 2 "`lab_dc'") rows(1) position(6) size(small)) name(cx_w, replace) nodraw
		graph combine cx_m cx_w, cols(2) ycommon graphregion(color(white))	///
			title("All old-age retirees in payment, by age and system (`y')", size(medlarge) color("`navy'"))
		cx_save 02b_oldage_pensions_by_age_`y'
	restore
}


********************************************************************************
//	03  AVERAGE OLD-AGE PENSION IN PAYMENT BY SYSTEM
use `stock', clear
keep if pension_type == 1
collapse (sum) benefit_sum=ben_sum n_pay, by(year pension_class)
generate avg_pension_thousands = benefit_sum / n_pay / 1000
keep year pension_class avg_pension_thousands
cx_labels
label values pension_class cx_sys
decode pension_class, generate(system)
cx_xlsx 03_avg_oldage_pension_by_system data
drop system
reshape wide avg_pension_thousands, i(year) j(pension_class)
twoway 	(line avg_pension_thousands1 year, lcolor("`steel'") lwidth(medthick))		///
		(line avg_pension_thousands2 year, lcolor("`navy'") lwidth(medthick)),		///
		title("Average old-age pension in payment, by system", size(medlarge) color("`navy'"))	///
		ytitle("Thousands of pesos per month (nominal)") xtitle("Year") `ycommon' `gcommon'	///
		legend(order(1 "`lab_db'" 2 "`lab_dc'") rows(1) position(6) size(small))
cx_save 03_avg_oldage_pension_by_system


********************************************************************************
//	04  AGE DISTRIBUTION OF NEW RETIREES, ALL AND AT THE MINIMUM PENSION
use `newret', clear
keep if gets_lumpsum != 1 & !missing(pension_benefit)
generate w_all = weight
generate w_min = weight * (minimum_pension == 1)
collapse (sum) w_all w_min, by(year pension_class age_retired)
generate retirees_thousands = w_all / 1000
generate at_minimum_thousands = w_min / 1000
generate above_floor_thousands = retirees_thousands - at_minimum_thousands
cx_labels
label values pension_class cx_sys
decode pension_class, generate(system)
keep year system pension_class age_retired retirees_thousands at_minimum_thousands above_floor_thousands
cx_xlsx 04_new_retirees_by_age data
tempfile nr_age
save `nr_age'
foreach y of local distyears {
	use `nr_age', clear
	keep if year == `y'
	foreach c in 1 2 {
		local lab = cond(`c' == 1, "`lab_db'", "`lab_dc'")
		quietly count if pension_class == `c'
		if r(N) > 0 {
			twoway 	(bar retirees_thousands age_retired if pension_class == `c', color("`lsteel'") barwidth(0.8))	///
					(bar at_minimum_thousands age_retired if pension_class == `c', color("`navy'") barwidth(0.8)),	///
					title("`lab'", size(medsmall) color("`navy'") position(11)) ytitle("Thousands") xtitle("Age at retirement") `ycommon' `gcommon'	///
					legend(order(2 "At the minimum" 1 "All new retirees") rows(1) position(6) size(small)) name(cx_c`c', replace) nodraw
		}
		else {
			twoway scatteri 0 0, title("`lab' (no new retirees)", size(medsmall) color("`navy'") position(11)) `gcommon' name(cx_c`c', replace) nodraw
		}
	}
	graph combine cx_c1 cx_c2, cols(2) graphregion(color(white))	///
		title("New old-age retirees by age and system, `y': all, and those at the minimum", size(medlarge) color("`navy'"))
	cx_save 04_new_retirees_by_age_`y'
}


********************************************************************************
//	05  SHARE OF NEW RETIREES AT THE MINIMUM PENSION
//	05a  By wage decile at retirement (all projection years, and by year in the Excel file)
use `newret', clear
keep if gets_lumpsum != 1 & !missing(pension_benefit) & !missing(wage_decile_ret)
generate w_all = weight
generate w_min = weight * (minimum_pension == 1)
preserve
	collapse (sum) w_all w_min, by(year pension_class wage_decile_ret)
	generate share_at_minimum_pct = 100 * w_min / w_all
	cx_labels
	label values pension_class cx_sys
	decode pension_class, generate(system)
	rename (w_all w_min) (new_retirees at_minimum)
	cx_xlsx 05a_min_pension_share_by_decile_and_year data
restore
collapse (sum) w_all w_min, by(pension_class wage_decile_ret)
generate share_at_minimum_pct = 100 * w_min / w_all
cx_labels
label values pension_class cx_sys
decode pension_class, generate(system)
rename (w_all w_min) (new_retirees at_minimum)
cx_xlsx 05a_min_pension_share_by_decile data
drop system
reshape wide share_at_minimum_pct new_retirees at_minimum, i(wage_decile_ret) j(pension_class)
foreach v in share_at_minimum_pct1 share_at_minimum_pct2 {
	capture confirm variable `v'
	if _rc generate `v' = .
}
generate dec_a = wage_decile_ret - 0.2
generate dec_b = wage_decile_ret + 0.2
twoway 	(bar share_at_minimum_pct1 dec_a, barwidth(0.4) color("`steel'"))	///
		(bar share_at_minimum_pct2 dec_b, barwidth(0.4) color("`navy'")),	///
		title("Share of new retirees at the minimum pension, by wage decile at retirement", size(medlarge) color("`navy'"))	///
		ytitle("Percent of new retirees") xtitle("Wage decile at retirement") xlabel(1(1)10, labsize(small) nogrid)	///
		ylabel(0(20)100, angle(0) grid glcolor(gs14) labsize(small)) `gcommon'	///
		legend(order(1 "`lab_db'" 2 "`lab_dc'") rows(1) position(6) size(small))
cx_save 05a_min_pension_share_by_decile

//	05b  By age at retirement and gender
use `newret', clear
keep if gets_lumpsum != 1 & !missing(pension_benefit) & inrange(age_retired, 55, 75)
generate w_all = weight
generate w_min = weight * (minimum_pension == 1)
collapse (sum) w_all w_min, by(pension_class gender age_retired)
generate share_at_minimum_pct = 100 * w_min / w_all
cx_labels
label values pension_class cx_sys
label values gender cx_gen
decode pension_class, generate(system)
decode gender, generate(gender_name)
rename (w_all w_min) (new_retirees at_minimum)
cx_xlsx 05b_min_pension_share_by_age_gender data
foreach c in 1 2 {
	local lab = cond(`c' == 1, "`lab_db'", "`lab_dc'")
	twoway 	(line share_at_minimum_pct age_retired if pension_class == `c' & gender == 1, lcolor("`navy'") lwidth(medthick))	///
			(line share_at_minimum_pct age_retired if pension_class == `c' & gender == 2, lcolor("`maroon'") lwidth(medthick) lpattern(dash)),	///
			title("`lab'", size(medsmall) color("`navy'") position(11)) ytitle("Percent of new retirees") xtitle("Age at retirement")	///
			ylabel(0(20)100, angle(0) grid glcolor(gs14) labsize(small)) xlabel(, labsize(small) nogrid) `gcommon'	///
			legend(order(1 "Men" 2 "Women") rows(1) position(6) size(small)) name(cx_c`c', replace) nodraw
}
graph combine cx_c1 cx_c2, cols(2) ycommon graphregion(color(white))	///
	title("Share of new retirees at the minimum pension, by age and gender", size(medlarge) color("`navy'"))
cx_save 05b_min_pension_share_by_age_gender


********************************************************************************
//	06  TOTAL PENSION PAYMENTS BY SYSTEM AND YEAR (all pension types, annual, nominal)
use `stock', clear
collapse (sum) monthly_payments=ben_sum, by(year pension_class)
fillin year pension_class
replace monthly_payments = 0 if missing(monthly_payments)
drop _fillin
generate payments_billions = 12 * monthly_payments / 1e9
cx_labels
label values pension_class cx_sys
decode pension_class, generate(system)
keep year pension_class system payments_billions
cx_xlsx 06_total_pension_payments_by_system data
drop system
reshape wide payments_billions, i(year) j(pension_class)
generate cum1 = payments_billions1
generate cum2 = payments_billions1 + payments_billions2
twoway 	(area cum2 year, color("`navy'") lcolor("`navy'"))		///
		(area cum1 year, color("`steel'") lcolor("`steel'")),	///
		title("Total pension payments, by system", size(medlarge) color("`navy'"))	///
		ytitle("Billions of pesos per year (nominal)") xtitle("Year") `ycommon' `gcommon'	///
		legend(order(2 "`lab_db'" 1 "`lab_dc'") rows(1) position(6) size(small))
cx_save 06_total_pension_payments_by_system


********************************************************************************
//	07  OLD-AGE PENSION EXPENDITURE BY COMPONENT, SHARE OF GDP     and
//	12  TOTAL OLD-AGE PENSION SPENDING, SHARE OF GDP
if `has_gdp' == 1 {
	use `stock', clear
	keep if pension_type == 1
	collapse (sum) ben_sum sub_sum, by(year pension_class)
	reshape wide ben_sum sub_sum, i(year) j(pension_class)
	foreach v in ben_sum1 ben_sum2 sub_sum1 sub_sum2 {
		capture confirm variable `v'
		if _rc generate `v' = 0
		replace `v' = 0 if missing(`v')
	}
	merge 1:1 year using `gdp', nogenerate keep(1 3)
	generate pensions_db_net_pct_gdp  = 100 * 12 * (ben_sum1 - sub_sum1) / gdp
	generate annuities_dc_net_pct_gdp = 100 * 12 * (ben_sum2 - sub_sum2) / gdp
	generate topups_pct_gdp           = 100 * 12 * (sub_sum1 + sub_sum2) / gdp
	generate total_oldage_pct_gdp     = pensions_db_net_pct_gdp + annuities_dc_net_pct_gdp + topups_pct_gdp
	rename (pensions_db_net_pct_gdp annuities_dc_net_pct_gdp) (db_net_of_topups_pct_gdp dc_net_of_topups_pct_gdp)
	keep year gdp db_net_of_topups_pct_gdp dc_net_of_topups_pct_gdp topups_pct_gdp total_oldage_pct_gdp
	cx_xlsx 07_oldage_expenditure_by_component_gdp data
	generate cum1 = db_net_of_topups_pct_gdp
	generate cum2 = cum1 + dc_net_of_topups_pct_gdp
	generate cum3 = cum2 + topups_pct_gdp
	twoway 	(area cum3 year, color("`maroon'") lcolor("`maroon'"))	///
			(area cum2 year, color("`navy'") lcolor("`navy'"))		///
			(area cum1 year, color("`steel'") lcolor("`steel'")),	///
			title("Old-age pension expenditure by component, share of GDP", size(medlarge) color("`navy'"))	///
			ytitle("Percent of GDP") xtitle("Year") `ycommon' `gcommon'	///
			legend(order(3 "`lab_db' pensions (net of top-ups)" 2 "`lab_dc' annuities (net of top-ups)" 1 "Government top-ups") rows(1) position(6) size(small))
	cx_save 07_oldage_expenditure_by_component_gdp

	preserve
		keep year total_oldage_pct_gdp
		cx_xlsx 12_oldage_spending_gdp data
	restore
	twoway 	(line total_oldage_pct_gdp year, lcolor("`navy'") lwidth(medthick)),	///
			title("Total old-age pension spending, share of GDP", size(medlarge) color("`navy'"))	///
			ytitle("Percent of GDP") xtitle("Year") `ycommon' `gcommon' legend(off)
	cx_save 12_oldage_spending_gdp
}


********************************************************************************
//	08  GOVERNMENT TOP-UP PER RECIPIENT, BY WAGE QUINTILE AND GENDER
use `stock', clear
keep if pension_type == 1 & !missing(wage_decile_ret) & sub_n > 0
generate quintile = ceil(wage_decile_ret / 2)
collapse (sum) sub_sum sub_n, by(year pension_class gender quintile)
generate topup_per_recipient_thousands = sub_sum / sub_n / 1000
keep year pension_class gender quintile topup_per_recipient_thousands
cx_labels
label values pension_class cx_sys
label values gender cx_gen
decode pension_class, generate(system)
decode gender, generate(gender_name)
cx_xlsx 08_topup_per_recipient_by_quintile_gender data
drop system gender_name
reshape wide topup_per_recipient_thousands, i(year pension_class gender) j(quintile)
forvalues q = 1/5 {
	capture confirm variable topup_per_recipient_thousands`q'
	if _rc generate topup_per_recipient_thousands`q' = 0
	replace topup_per_recipient_thousands`q' = 0 if missing(topup_per_recipient_thousands`q')
}
generate c1 = topup_per_recipient_thousands1
generate c2 = c1 + topup_per_recipient_thousands2
generate c3 = c2 + topup_per_recipient_thousands3
generate c4 = c3 + topup_per_recipient_thousands4
generate c5 = c4 + topup_per_recipient_thousands5
local panel = 0
foreach c in 1 2 {
	foreach g in 1 2 {
		local ++panel
		local lab = cond(`c' == 1, "`lab_db'", "`lab_dc'") + cond(`g' == 1, " - Men", " - Women")
		quietly count if pension_class == `c' & gender == `g'
		if r(N) > 0 {
			twoway 	(area c5 year if pension_class == `c' & gender == `g', color("`maroon'") lcolor("`maroon'"))	///
					(area c4 year if pension_class == `c' & gender == `g', color("`rose'") lcolor("`rose'"))		///
					(area c3 year if pension_class == `c' & gender == `g', color("`navy'") lcolor("`navy'"))	///
					(area c2 year if pension_class == `c' & gender == `g', color("`steel'") lcolor("`steel'"))	///
					(area c1 year if pension_class == `c' & gender == `g', color("`lsteel'") lcolor("`lsteel'")),	///
					title("`lab'", size(medsmall) color("`navy'") position(11)) ytitle("Thousands, pesos/month") xtitle("Year")	///
					`ycommon' `gcommon' legend(order(5 "Q1" 4 "Q2" 3 "Q3" 2 "Q4" 1 "Q5") rows(1) position(6) size(small)) name(cx_p`panel', replace) nodraw
		}
		else {
			twoway scatteri 0 0, title("`lab' (no recipients)", size(medsmall) color("`navy'") position(11)) `gcommon' name(cx_p`panel', replace) nodraw
		}
	}
}
graph combine cx_p1 cx_p2 cx_p3 cx_p4, cols(2) graphregion(color(white))	///
	title("Government top-up per recipient, by wage quintile and gender", size(medlarge) color("`navy'"))
cx_save 08_topup_per_recipient_by_quintile_gender


********************************************************************************
//	09  SHARE RECEIVING A TOP-UP AND AVERAGE SIZE, BY WAGE DECILE AT RETIREMENT
//	    (stock of old-age pensioners at the end of the projection)
use `stock', clear
keep if pension_type == 1 & year == `y1' & !missing(wage_decile_ret)
collapse (sum) n_pay sub_n subpct_sum, by(pension_class wage_decile_ret)
cx_labels
label values pension_class cx_sys
decode pension_class, generate(system)
generate share_receiving_topup_pct = 100 * sub_n / n_pay
generate avg_topup_pct_of_own_wage = subpct_sum / sub_n
rename (n_pay sub_n) (pensioners recipients)
cx_xlsx 09_topup_share_and_size_by_decile data
//	chart: all systems together
use `stock', clear
keep if pension_type == 1 & year == `y1' & !missing(wage_decile_ret)
collapse (sum) n_pay sub_n subpct_sum, by(wage_decile_ret)
generate share_receiving_topup_pct = 100 * sub_n / n_pay
generate avg_topup_pct_of_own_wage = subpct_sum / sub_n
twoway 	(bar share_receiving_topup_pct wage_decile_ret, barwidth(0.65) color("`navy'")),	///
		title("Share receiving a top-up", size(medsmall) color("`navy'") position(11)) ytitle("Percent of pensioners") xtitle("Wage decile at retirement")	///
		xlabel(1(1)10, labsize(small) nogrid) ylabel(0(20)100, angle(0) grid glcolor(gs14) labsize(small)) `gcommon' legend(off) name(cx_a, replace) nodraw
twoway 	(bar avg_topup_pct_of_own_wage wage_decile_ret, barwidth(0.65) color("`maroon'")),	///
		title("Average top-up of recipients", size(medsmall) color("`navy'") position(11)) ytitle("Percent of the recipient's own wage") xtitle("Wage decile at retirement")	///
		xlabel(1(1)10, labsize(small) nogrid) ylabel(#6, angle(0) grid glcolor(gs14) labsize(small)) `gcommon' legend(off) name(cx_b, replace) nodraw
graph combine cx_a cx_b, cols(2) graphregion(color(white))	///
	title("Government top-up: share receiving and average size, by wage decile", size(medlarge) color("`navy'"))	///
	note("Pensioner stock in `y1'; top-up = government-financed component of the pension, as a percent of the recipient's own wage.", size(vsmall) color(gs8))
cx_save 09_topup_share_and_size_by_decile


********************************************************************************
//	10  SHARE RETIRING WITH A LUMP SUM, BY WAGE DECILE AND YEAR
use `newret', clear
keep if !missing(wage_decile_ret)
generate w_all  = weight
generate w_lump = weight * (gets_lumpsum == 1)
preserve
	collapse (sum) w_all w_lump, by(year pension_class wage_decile_ret)
	generate lump_sum_share_pct = 100 * w_lump / w_all
	cx_labels
	label values pension_class cx_sys
	decode pension_class, generate(system)
	rename (w_all w_lump) (new_retirees take_lump_sum)
	cx_xlsx 10_lump_sum_share_by_decile_and_year data
restore
tempfile lsfile
preserve
	collapse (sum) w_all w_lump, by(year wage_decile_ret)
	generate lump_sum_share_pct = 100 * w_lump / w_all
	save `lsfile'
restore
collapse (sum) w_all w_lump, by(wage_decile_ret)
generate lump_sum_share_pct = 100 * w_lump / w_all
twoway 	(bar lump_sum_share_pct wage_decile_ret, barwidth(0.65) color("`grey'")),	///
		title("By wage decile at retirement (all years)", size(medsmall) color("`navy'") position(11)) ytitle("Percent of new retirees") xtitle("Wage decile at retirement")	///
		xlabel(1(1)10, labsize(small) nogrid) ylabel(0(20)100, angle(0) grid glcolor(gs14) labsize(small)) `gcommon' legend(off) name(cx_a, replace) nodraw
use `lsfile', clear
twoway 	(line lump_sum_share_pct year if wage_decile_ret == 1, lcolor("`maroon'") lwidth(medthick))		///
		(line lump_sum_share_pct year if wage_decile_ret == 5, lcolor("`steel'") lwidth(medthick))		///
		(line lump_sum_share_pct year if wage_decile_ret == 10, lcolor("`navy'") lwidth(medthick)),	///
		title("By year, for deciles 1, 5 and 10", size(medsmall) color("`navy'") position(11)) ytitle("Percent of new retirees") xtitle("Year")	///
		ylabel(0(20)100, angle(0) grid glcolor(gs14) labsize(small)) xlabel(, labsize(small) nogrid) `gcommon'	///
		legend(order(1 "Decile 1" 2 "Decile 5" 3 "Decile 10") rows(1) position(6) size(small)) name(cx_b, replace) nodraw
graph combine cx_a cx_b, cols(2) graphregion(color(white))	///
	title("Share retiring with a lump sum", size(medlarge) color("`navy'"))
cx_save 10_lump_sum_share_by_decile_and_year


********************************************************************************
//	11  RETIREMENT OUTCOMES BY WAGE DECILE
//	    lump-sum share, replacement rate and income adequacy, lifetime pension (all years pooled)
use `newret', clear
keep if !missing(wage_decile_ret)
generate w_all  = weight
generate w_lump = weight * (gets_lumpsum == 1)
tempfile outc1 outc2
preserve
	collapse (sum) w_all w_lump, by(wage_decile_ret)
	generate lump_sum_share_pct = 100 * w_lump / w_all
	keep wage_decile_ret lump_sum_share_pct
	save `outc1'
restore
keep if gets_lumpsum != 1 & !missing(pension_benefit) & !missing(replacement_rate)
generate double lifetime_multiple = pension_benefit * life_expectancy / average_wage
generate double w = weight
foreach v in replacement_rate income_adequacy lifetime_multiple {
	generate double wx_`v' = w * `v'
}
collapse (sum) w wx_replacement_rate wx_income_adequacy wx_lifetime_multiple, by(wage_decile_ret)
generate replacement_rate_pct       = wx_replacement_rate / w
generate income_adequacy_pct        = wx_income_adequacy / w
generate lifetime_pension_multiple  = wx_lifetime_multiple / w
rename w pensioners
keep wage_decile_ret pensioners replacement_rate_pct income_adequacy_pct lifetime_pension_multiple
merge 1:1 wage_decile_ret using `outc1', nogenerate
order wage_decile_ret lump_sum_share_pct replacement_rate_pct income_adequacy_pct lifetime_pension_multiple pensioners
cx_xlsx 11_retirement_outcomes_by_decile data
generate dec_a = wage_decile_ret - 0.2
generate dec_b = wage_decile_ret + 0.2
twoway 	(bar lump_sum_share_pct wage_decile_ret, barwidth(0.65) color("`grey'")),	///
		title("Share taking a lump sum", size(medsmall) color("`navy'") position(11)) ytitle("Percent of outcomes") xtitle("Wage decile at retirement")	///
		xlabel(1(1)10, labsize(small) nogrid) ylabel(0(20)100, angle(0) grid glcolor(gs14) labsize(small)) `gcommon' legend(off) name(cx_a, replace) nodraw
twoway 	(bar replacement_rate_pct dec_a, barwidth(0.4) color("`maroon'"))	///
		(bar income_adequacy_pct dec_b, barwidth(0.4) color("`navy'")),		///
		title("Replacement rate and income adequacy, pensioners", size(medsmall) color("`navy'") position(11)) ytitle("Percent") xtitle("Wage decile at retirement")	///
		xlabel(1(1)10, labsize(small) nogrid) ylabel(#6, angle(0) grid glcolor(gs14) labsize(small)) `gcommon'	///
		legend(order(1 "Replacement rate (own wage)" 2 "Income adequacy (economy wage)") rows(1) position(6) size(small)) name(cx_b, replace) nodraw
twoway 	(bar lifetime_pension_multiple wage_decile_ret, barwidth(0.65) color("`steel'")),	///
		title("Total pension received over the lifetime", size(medsmall) color("`navy'") position(11)) ytitle("Times the annual economy-average wage") xtitle("Wage decile at retirement")	///
		xlabel(1(1)10, labsize(small) nogrid) ylabel(#6, angle(0) grid glcolor(gs14) labsize(small)) `gcommon' legend(off) name(cx_c, replace) nodraw
graph combine cx_a cx_b cx_c, cols(2) graphregion(color(white))	///
	title("Retirement outcomes across the wage distribution", size(medlarge) color("`navy'"))	///
	note("Lifetime pension = initial monthly pension x expected remaining years of life at retirement, divided by the economy-average monthly wage.", size(vsmall) color(gs8))
cx_save 11_retirement_outcomes_by_decile


********************************************************************************
//	13  AVERAGE REPLACEMENT RATE BY YEAR, AND BY PENSION CLASS
use `newret', clear
keep if gets_lumpsum != 1 & !missing(pension_benefit) & !missing(replacement_rate)
generate double w  = weight
generate double wx = weight * replacement_rate
tempfile rr_all
preserve
	collapse (sum) w wx, by(year)
	generate avg_replacement_rate_pct = wx / w
	generate pension_class = 0
	save `rr_all'
restore
collapse (sum) w wx, by(year pension_class)
generate avg_replacement_rate_pct = wx / w
append using `rr_all'
label define cx_sys0 0 "All new retirees" 1 "`lab_db'" 2 "`lab_dc'", replace
label values pension_class cx_sys0
decode pension_class, generate(group)
rename w pensioners
keep year group pension_class pensioners avg_replacement_rate_pct
sort pension_class year
cx_xlsx 13_replacement_rate_by_year_and_class data
twoway 	(line avg_replacement_rate_pct year if pension_class == 0, lcolor("`navy'") lwidth(medthick)),	///
		title("All new retirees", size(medsmall) color("`navy'") position(11)) ytitle("Percent of own wage") xtitle("Year")	///
		`ycommon' `gcommon' legend(off) name(cx_a, replace) nodraw
twoway 	(line avg_replacement_rate_pct year if pension_class == 1, lcolor("`steel'") lwidth(medthick))		///
		(line avg_replacement_rate_pct year if pension_class == 2, lcolor("`navy'") lwidth(medthick)),	///
		title("By pension class", size(medsmall) color("`navy'") position(11)) ytitle("Percent of own wage") xtitle("Year")	///
		`ycommon' `gcommon' legend(order(1 "`lab_db'" 2 "`lab_dc'") rows(1) position(6) size(small)) name(cx_b, replace) nodraw
graph combine cx_a cx_b, cols(2) graphregion(color(white))	///
	title("Average replacement rate of new retirees", size(medlarge) color("`navy'"))
cx_save 13_replacement_rate_by_year_and_class

capture graph drop _all
display as result _n "Charts and Excel files saved in `chartdir'"
