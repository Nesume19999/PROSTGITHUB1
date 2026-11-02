/******************************************************************************* 
Title: 			Estimate transitions rates from longitudinal data - EXTREMELY LOW DATA
Author: 		Duncan MacDonald 
Date created: 	March 18th, 2026
Description:	For building PROST v2 pension model (Revised)


Transition out model: 
	cloglog transition_out c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.los_gap if den == 1, cluster(id) 
	
Transition in model: 
	cloglog transition_in c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.log_cod c.los_gap if dens == 0, cluster(id)
	
	
Note: This code uses gtools and ftools to speed up processing
Source: https://gtools.readthedocs.io/en/latest/
Source: https://github.com/sergiocorreia/ftools

Commands:
ssc install gtools
ssc install ftools


Note: Here we define deciles as the last known decile of the person as the decile 
	  they had for their entire career. 
	  That is, their most recent decile is their "true" decile.
			
*******************************************************************************/	

//	INITIALIZATION
	clear all
	pause on
	set trace off
	
// 	SETS THE SEED OF THE RANDOM NUMBER GENERATOR
//	Note: Any seed works the same. 
//	The idea is to set it to one specific value so to have the same resuts when the model is re-run
	set seed 2

//	Country iso3 code
	local country  = "MEX"

//	SET PARAMETERS, AND THE NAME OF FOLDER AND FILES OF THE EXERCISE:
	local indir		 = "C:\Users\Duncan\OneDrive\World Bank\Generic\Input"
	local homedir 		= "C:\Users\Duncan\OneDrive\World Bank\MEX"
	local transdir		= "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\transitions"

//	Name of input data	
	local low_data 		= "lowdata_`country'"
	local very_low_data = "verylowdata_`country'"
	local extremely_low_data = "extremelylowdata_`country'"
	local long_data  = "2 Input from client - longitudinal microdata about affiliates.dta"


//	Simulation parameters
	local years_avg   = 10  	// Number of years of back data that are averaged to generate (we use 1 right now to )
	local minimum_age = 15		// Minimum age to consider (some young ages don't have a lot of data)
	local samplesize  = 10		// Sample size of the projection database (100 is a full sample, 1 is a 1% sample) - [Only when testing]

	
//	Output model names	
	local job_exit_model 		= "job_exit_model_`country'_`years_avg'_final_EXTREMELY_LOW_DATA"
	local job_entry_model 		= "job_entry_model_`country'_`years_avg'_final_EXTREMELY_LOW_DATA"
	
	
//	Parameters of the current pension system
//	We need these as we compute transition rates as a function of time to retirement
	local retage_earliest = 60				// Easliest possible retirement age - (Cesantía en Edad Avanzada)
	local retage_male = 65 					// Male retirement age
	local retage_female = 65				// Female retirement age
	local retcont_min = (750 / 52) * 12		// Minimum contribution threshold (in months)

	
********************************************************************************
// 	Open the longitudinal microdata about affiliates
// 	cd "`homedir'"
// 	use "`long_data'", clear
	cd "`indir'"
	use "`extremely_low_data'", clear
	
	
//	Get the latest year of the dataset
	summarize year
	local latest_year = r(max)
	local earliest_year = r(min)

// 	Sort the annual data into 5-year bands (to reduce noise)
	generate age = year - yob
	
//	Minor cleanup
	rename aux loa
	label variable loa "Length of affiliation (months)"
	
	


********************************************************************************
//	Compute spells of unemployment and job tenure

//	Set up time series data
// 	generate date = ym(year, month)
// 	sort id date
	sort id year
	
//	Impute approximate spell length
	generate spell_length = los
	replace  spell_length = loa - los if dens == 0


//	Compute contribution density
	generate contribution_density = los / loa
	
//	Length of association in years	
	generate loa_years = floor(loa / 12)

	
//	Compute log of contribution density
	generate log_cod = log(max(contribution_density, 0.001))
	
	
********************************************************************************
// Compute some pension-rule-specific indicators (for inclusion into the model)	
	
// 	Months until reaching eligible retirement age
	generate age_gap = 0
	replace  age_gap = max(`retage_male'   - age, 0) * 12 if gender == 1 // Male
	replace  age_gap = max(`retage_female' - age, 0) * 12 if gender == 2 // Female
	
// 	Months of contributions requred to be eligible for an old-age pension
	generate los_gap = max(`retcont_min' - los, 0)
	
// 	As both age_gap and los_gap must be filled, we take the max for the model
	generate pension_gap = max(age_gap, los_gap)
	
//	Indicator: person has no hope of being eligible for a pension
	generate no_hope = (los_gap  >= age_gap)
	
//	Determine the earliest age at which people can retirement
	generate retirement_age = (age >= `retage_earliest')
	
	
	
********************************************************************************	
//	Build a wage growth index from your own data (mean wage each year)
	bysort year: egen mean_wage_yr = mean(wage)				// Average wage in each year
	generate wage_relative_mean = wage / mean_wage_yr   	// Compute the wage relative to the mean 
// 	sort id date											// Sort the data
// 	by id: carryforward wage_relative_mean, replace			// Carry the latest non-missing data forward
	
//  Deciles (using faster gtools) [Compute using relative wages, so we don't need to index]
	*gquantiles wage_decile_ref_last = wage_relative_mean if year == `latest_year' & month==12 , xtile nquantiles(10) by(year) 
	gquantiles wage_decile_ref = wage_relative_mean, xtile nquantiles(10) by(year) 
// 	bysort id: egen wage_decile_ref = max(wage_decile_ref_last)
// 	drop wage_decile_ref_last
	
	
//	Compute a reference wage decile (for those people who are not working currently)
	generate wage_decile = wage_decile_ref
	
//	Fill in observed wage_decile with 0 when not working formally
	replace  wage_decile = 0 if dens ==0 // Unemployed or working informally
	
	
	
// 	Pre-processing (drop data and compute wage deciles)
	// Keep only the most recent years
	// Note: We do this only after getting a person's wage_decile_ref
	*keep if year > `latest_year'  - `years_avg'
	keep if age >= `minimum_age'


********************************************************************************
//	Compute transiiton rates
// 	Note: As we cannot estimate transition rates directly then we need to compute aggregate transition rates from contribution density
//	Steady state employment rate:  los / loa = λ_in / (λ_in + λ_out) 
//	TODO: We might need some correction for non-staeady state:
// 	los/loa = λ_in/(λ_in+λ_out ) + λ_out/(λ_in+λ_out )*((1-e^(-(λ_in+λ_out )*loa))/(λ_in+λ_out )*loa)

//	First, get the average transition_out rate for those in work by wage decile, gender and age
//	We do this by looking at the number of workers with less than 12 contributions in the current year
//	We compare this with the number of active months were worked within each cohort
//	TODO: Do we want to consider this using 5-year age groups (to protect against small sample sizes)
	generate did_transition = (dens > 0 & dens < 12)
	bysort wage_decile_ref gender age: egen transitions = total(did_transition) // Number of transitions E -> U
	bysort wage_decile_ref gender age: egen months_worked = total(dens) 		// Number of months worked
	generate transition_out = transitions / months_worked

//	Then we compute transition_in rates based on the steady state employment rate equation:
	generate adjustment = (contribution_density / (1 - contribution_density))
	generate transition_in_ind = transition_out * (contribution_density / (1 - contribution_density))
	replace  transition_in_ind = min(transition_in_ind, 1)	// Put a cap on transition_in_ind
	
//	Get the average contribution density by wage decile, age, and gender
	bysort wage_decile_ref gender age: egen transition_in = mean(transition_in_ind) 		
	
	





********************************************************************************
//	Estimating spell-dependent transition rates
//	Note: We use a GLM model here as our data is no longer 0 and 1, but rather [0,1]


//	Estimate using GLM with the cloglog link
// 	Note: We focus on those with low in-year density as an approximation of those who are currently out of work
	glm transition_in_ind c.spell_length i.wage_decile_ref c.age##c.age i.gender c.log_cod c.los_gap i.retirement_age i.no_hope if dens <= 2, family(binomial) link(cloglog) cluster(id)
	predict entry_extremely_low_data
	cd "`transdir'"
	estimates save "`job_entry_model'", replace
	
//	Update our transition out_rates
// 	Note: We focus on those with high in-year density as an approximation of those who are currently in work
	generate transition_out_ind = entry_extremely_low_data * (1/adjustment)
	glm transition_out_ind c.spell_length##i.wage_decile_ref c.age##c.age i.gender c.los_gap  i.retirement_age i.no_hope if dens >= 11, family(binomial) link(cloglog) cluster(id)
	predict exit_extremely_low_data
	cd "`transdir'"
	estimates save "`job_exit_model'", replace




	
	
********************************************************************************	


cd "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\transitions"
estimates use "job_entry_model_MEX_10_final"
estimates replay "job_entry_model_MEX_10_final"
capture drop entry_final
predict entry_final

estimates use "job_entry_model_MEX_10_final_LOW_DATA"
estimates replay "job_entry_model_MEX_10_final_LOW_DATA"
capture drop entry_low_data
predict entry_low_data
hist entry_low_data

estimates use "job_entry_model_MEX_10_final_VERY_LOW_DATA"
estimates replay "job_entry_model_MEX_10_final_VERY_LOW_DATA"
capture drop entry_very_low_data
predict entry_very_low_data
*hist entry_very_low_data


// twoway (hist entry_final, color(red)) (hist entry_low_data, color(green)) (hist entry_very_low_data, color(blue)) (hist entry_extremely_low_data, color(orange)) , legend(label(1 "Full model") label(2 "Low Data") label(3 "Very Low Data") label(4 "Extremely Low Data"))	 name("In")

twoway (kdensity entry_final, color(red)) (kdensity entry_low_data, color(green)) (kdensity entry_very_low_data, color(blue)) (kdensity entry_extremely_low_data, color(orange)) , legend(label(1 "Full model") label(2 "Low Data") label(3 "Very Low Data") label(4 "Extremely Low Data"))	 name("In")


// twoway (hist entry_final) (hist entry_low_data) if  dens == 0


*keep transition_in spell_length wage_decile_ref age gender log_cod los_gap dens



cd "C:\Users\Duncan\OneDrive\World Bank\Generic\Input\Defaults\transitions"
estimates use "job_exit_model_MEX_10_final"
estimates replay "job_exit_model_MEX_10_final"
capture drop exit_final
predict exit_final

estimates use "job_exit_model_MEX_10_final_LOW_DATA"
estimates replay "job_exit_model_MEX_10_final_LOW_DATA"
capture drop exit_low_data
predict exit_low_data
hist exit_low_data

estimates use "job_exit_model_MEX_10_final_VERY_LOW_DATA"
estimates replay "job_exit_model_MEX_10_final_VERY_LOW_DATA"
capture drop exit_very_low_data
predict exit_very_low_data
hist exit_very_low_data



// twoway (hist exit_final, color(red)) (hist exit_low_data, color(green)) (hist exit_very_low_data, color(blue)) (hist exit_extremely_low_data, color(orange)) , legend(label(1 "Full model") label(2 "Low Data") label(3 "Very Low Data") label(4 "Extremely Low Data"))	 name("Out")

twoway (kdensity exit_final, color(red)) (kdensity exit_low_data, color(green)) (kdensity exit_very_low_data, color(blue)) (kdensity exit_extremely_low_data, color(orange)) , legend(label(1 "Full model") label(2 "Low Data") label(3 "Very Low Data") label(4 "Extremely Low Data"))	 name("Out")


// twoway (hist exit_final) (hist exit_low_data) if  dens == 1
// hist exit_final if  dens == 1
// hist exit_low_data if  dens == 1

	