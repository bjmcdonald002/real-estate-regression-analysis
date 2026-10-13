# Real estate sales input

`real_estate_sales.csv` is an exact numeric export of the authoritative
`Data Set C7.xlsx` from the original coursework archive. It contains 522
observations, preserving original row order, and no missing values.

Source: Kutner, M. H., Nachtsheim, C. J., and Neter, J. (2004),
*Applied Linear Regression Models*, 4th edition, Data Set C.7, Real Estate Sales.
The original project cites page 682. Attribution and definitions were checked
against the table reproduced in the original report.

| Column | Meaning | Units / coding |
|---|---|---|
| Y | Sale price | Dollars |
| X1 | Finished area | Square feet |
| X2 | Bedrooms | Count |
| X3 | Bathrooms | Count |
| X4 | Air conditioning | 1 yes, 0 no |
| X5 | Garage capacity | Cars |
| X6 | Swimming pool | 1 yes, 0 no |
| X7 | Year built | Year |
| X8 | Construction quality | 1 high, 2 medium, 3 low |
| X9 | Architectural style | Nominal codes; labels unavailable |
| X10 | Lot size | Square feet |
| X11 | Adjacent to highway | 1 yes, 0 no |

Case identifiers 1–522 are derived from original row order. Natural log-price,
categorical variables, and style pooling are calculated by the R script.
The local package includes the input for running the analysis. The CSV is
excluded from Git because textbook-data redistribution permission has not
been established; attribution alone does not establish a license. A public
checkout requires a lawfully obtained copy with these column names.
