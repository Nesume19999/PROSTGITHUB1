	
// 	Open the data	
	use "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\pensioners_MEX.dta", replace
	
//	Only old-age retirees
	keep if pension_type == 1 // "Old-age"
	
//	Keep only DB pensioners_MEX
	keep if pension_class == 1 // DB
	
//	Compute age at retirement
	generate age_retired = age - (2020 - startyear)

//	Add some noise to the pension benefit to avoid ties
	generate benefit_adj = pension_benefit + runiform(0,1)

//  Deciles (using faster gtools) [Compute using relative wages, so we don't need to index]
	gquantiles pension_decile = benefit_adj , xtile nquantiles(10) by(startyear) 

//	Colapse and reshape
	collapse (count) tot=pension_benefit, by(pension_type pension_class age_retired pension_decile)
	reshape wide tot, i(age_retired pension_class pension_type) j(pension_decile)

//	Export the data
	export excel "C:\Users\Duncan\OneDrive\World Bank\Generic\Output\Age-Benefit distribution.xlsx", firstrow(variables) sheet("Data", replace)