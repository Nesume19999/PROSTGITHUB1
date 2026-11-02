// 10 percent sample
use "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\synthetic_affiliates_10pct_sample.dta", clear

keep if month ==12 
collapse (sum) weight, by(id)

save "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\synthetic_weights_10pct_sample.dta"



// 1 percent sample
use "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\synthetic_affiliates_1pct_sample.dta", clear

keep if month ==12 
collapse (sum) weight, by(id)

save "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\synthetic_weights_1pct_sample.dta"



// 01 percent sample
use "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\synthetic_affiliates_01pct_sample.dta", clear

keep if month ==12 
collapse (sum) weight, by(id)

save "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\synthetic_weights_01pct_sample.dta"