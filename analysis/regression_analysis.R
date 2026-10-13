# Real estate regression analysis, reconstructed from the original source data.
# Run from the repository root: source("analysis/regression_analysis.R")
# Base R only. Keep original row order for stable case identifiers.
stopifnot(file.exists("data/real_estate_sales.csv"))
dir.create("results", showWarnings = FALSE)
dir.create("figures", showWarnings = FALSE)
raw <- read.csv("data/real_estate_sales.csv")
stopifnot(nrow(raw) == 522L, !anyNA(raw), all(raw$Y > 0),
          identical(names(raw), c("Y", paste0("X", 1:11))))
raw$case_id <- seq_len(nrow(raw))

# Fixed preprocessing policy: treat quality as categorical and pool style codes
# with fewer than five TRAINING observations. Pooling is a sparsity assumption,
# not a claim that these styles are architecturally equivalent. Code labels are
# unavailable. An unseen validation code joins the training Other group.
prepare <- function(training, test = NULL) {
  counts <- table(as.character(training$X9))
  common <- names(counts)[counts >= 5L]
  pool <- names(counts)[counts < 5L]
  lev <- c(common, if (length(pool)) "Other")
  convert <- function(d) {
    style <- ifelse(as.character(d$X9) %in% common, as.character(d$X9), "Other")
    if (any(!style %in% lev)) stop("No training Other category for unseen style")
    transform(d, lnY = log(Y), X8 = factor(X8, levels = 1:3),
              X9 = factor(style, levels = lev))
  }
  list(train = convert(training), test = if (!is.null(test)) convert(test),
       common = common, pooled = pool)
}
all_terms <- paste0("X", 1:11)
subsets <- c(list(character(0)), unlist(lapply(1:11, function(k)
  combn(all_terms, k, simplify = FALSE)), recursive = FALSE))
make_formula <- function(v) if (length(v)) reformulate(v, "lnY") else lnY ~ 1

# Each categorical predictor enters/leaves as a complete term. All 2,048
# main-effect subsets are evaluated, including the intercept-only model.
select_bic <- function(d, export = FALSE) {
  full <- lm(make_formula(all_terms), d)
  full_mse <- deviance(full) / df.residual(full)
  tab <- do.call(rbind, lapply(subsets, function(v) {
    m <- lm(make_formula(v), d)
    s <- summary(m)
    data.frame(terms = if (length(v)) paste(v, collapse = "+") else "1",
      p = m$rank, RSS = deviance(m), R2 = s$r.squared,
      adjusted_R2 = s$adj.r.squared, AIC = AIC(m), BIC = BIC(m),
      Cp = deviance(m) / full_mse - nrow(d) + 2 * m$rank,
      PRESS = sum((resid(m) / (1 - hatvalues(m)))^2))
  }))
  winner <- which.min(tab$BIC)
  list(model = lm(make_formula(subsets[[winner]]), d),
       vars = subsets[[winner]], table = if (export) tab else NULL)
}
prepared <- prepare(raw)
data <- prepared$train
selection <- select_bic(data, export = TRUE)
model <- selection$model
full <- lm(make_formula(all_terms), data)
without_style <- lm(make_formula(setdiff(selection$vars, "X9")), data)
write.csv(selection$table, "results/subset_selection.csv", row.names = FALSE)
write.csv(data.frame(code = names(table(raw$X9)), count = as.integer(table(raw$X9)),
  model_group = ifelse(names(table(raw$X9)) %in% prepared$common,
                      names(table(raw$X9)), "Other")),
  "results/style_groups.csv", row.names = FALSE)

# Nine predictor-stratified folds. Stratification balances the rare pooled
# styles across folds; it does not choose a model or use sale prices.
# Training-only prepare() relearns the mapping and selection in every fold.
set.seed(20261012)
k <- 9L
fold <- integer(nrow(raw))
offset <- 0L
for (g in levels(data$X9)) {
  ids <- which(data$X9 == g)
  ids <- ids[sample.int(length(ids))]
  fold[ids] <- ((seq_along(ids) - 1L + offset) %% k) + 1L
  offset <- (offset + length(ids)) %% k
}
stopifnot(all(table(fold) == 58L))
predictions <- list()
fold_details <- list()
for (i in seq_len(k)) {
  cat("Validation fold", i, "of", k, "\n")
  test <- fold == i
  d <- prepare(raw[!test, ], raw[test, ])
  selected <- select_bic(d$train)
  # Select without style explicitly, retaining all other candidate predictors.
  no_style_vars <- setdiff(all_terms, "X9")
  no_style_subsets <- c(list(character(0)), unlist(lapply(seq_along(no_style_vars),
    function(j) combn(no_style_vars, j, simplify = FALSE)), recursive = FALSE))
  bic_ns <- vapply(no_style_subsets, function(v) BIC(lm(make_formula(v), d$train)), numeric(1))
  ns <- lm(make_formula(no_style_subsets[[which.min(bic_ns)]]), d$train)
  fits <- list(BIC_selected = selected$model,
               Full_model = lm(make_formula(all_terms), d$train),
               BIC_without_style = ns)
  for (name in names(fits)) {
    fit <- fits[[name]]
    log_pred <- as.numeric(predict(fit, d$test))
    # Duan smearing, estimated on training residuals only. Assumes a common
    # residual multiplier distribution; dollar predictions remain descriptive.
    smear <- mean(exp(resid(fit)))
    predictions[[length(predictions) + 1L]] <- data.frame(case_id = d$test$case_id,
      fold = i, model = name, actual_log_price = d$test$lnY,
      predicted_log_price = log_pred, actual_price = d$test$Y,
      predicted_price = exp(log_pred) * smear)
  }
  predictions[[length(predictions) + 1L]] <- data.frame(case_id = d$test$case_id,
    fold = i, model = "Intercept_baseline", actual_log_price = d$test$lnY,
    predicted_log_price = mean(d$train$lnY), actual_price = d$test$Y,
    predicted_price = mean(d$train$Y))
  fold_details[[i]] <- data.frame(fold = i, n_train = nrow(d$train), n_test = nrow(d$test),
    selected_terms = paste(selected$vars, collapse = "+"), p = selected$model$rank,
    pooled_codes = paste(d$pooled, collapse = "+"),
    no_style_terms = paste(no_style_subsets[[which.min(bic_ns)]], collapse = "+"))
}
pred <- do.call(rbind, predictions)
stopifnot(!anyNA(pred), all(is.finite(pred$predicted_price)))
metrics <- do.call(rbind, lapply(split(pred, pred$model), function(d)
  data.frame(model = d$model[1], n = nrow(d),
    log_RMSE = sqrt(mean((d$actual_log_price - d$predicted_log_price)^2)),
    log_MAE = mean(abs(d$actual_log_price - d$predicted_log_price)),
    dollar_RMSE = sqrt(mean((d$actual_price - d$predicted_price)^2)),
    dollar_MAE = mean(abs(d$actual_price - d$predicted_price)))))
write.csv(pred[order(pred$model, pred$case_id), ], "results/cv_predictions.csv", row.names = FALSE)
write.csv(metrics, "results/cv_metrics.csv", row.names = FALSE)
write.csv(do.call(rbind, fold_details), "results/cv_folds.csv", row.names = FALSE)

# Exploratory diagnostics on the final all-data fit; post-selection intervals
# and tests are descriptive, not adjusted for searching candidate models.
n <- nrow(data); p <- model$rank
dfb <- dfbetas(model)
diagnostics <- data.frame(case_id = data$case_id, fitted_log_price = fitted(model),
  residual = resid(model), studentized_deleted = rstudent(model),
  leverage = hatvalues(model), DFFITS = dffits(model), Cook = cooks.distance(model),
  max_abs_DFBETAS = apply(abs(dfb), 1, max))
diagnostics$bonferroni_p <- pmin(1, n * 2 * pt(-abs(diagnostics$studentized_deleted),
                                              df.residual(model) - 1))
diagnostics$leverage_flag <- diagnostics$leverage > 2 * p / n
diagnostics$DFFITS_flag <- abs(diagnostics$DFFITS) > 2 * sqrt(p / n)
diagnostics$DFBETAS_flag <- diagnostics$max_abs_DFBETAS > 2 / sqrt(n)
write.csv(diagnostics, "results/influence_diagnostics.csv", row.names = FALSE)
write.csv(data.frame(case_id = data$case_id, dfb), "results/dfbetas.csv", row.names = FALSE)
coefs <- summary(model)$coefficients
write.csv(data.frame(term = rownames(coefs), coefs, check.names = FALSE),
          "results/coefficients.csv", row.names = FALSE)
# Keep all cases in main analysis. Deletion flags are used only for sensitivity.
kept <- data[!diagnostics$DFFITS_flag, ]
sensitivity <- lm(formula(model), kept)
common_coef <- intersect(names(coef(model)), names(coef(sensitivity)))
write.csv(data.frame(term = common_coef, all_cases = coef(model)[common_coef],
  flagged_removed = coef(sensitivity)[common_coef],
  change_in_full_model_SE = (coef(sensitivity)[common_coef] - coef(model)[common_coef]) /
    sqrt(diag(vcov(model)))[common_coef]), "results/deletion_sensitivity.csv", row.names = FALSE)

# Exploratory hierarchy-preserving interaction search, with main effects fixed.
# It is not included in the primary validation or promoted as a selected winner.
interaction_formula <- as.formula(paste("lnY ~ (", paste(selection$vars, collapse = "+"), ")^2"))
interaction_full <- lm(interaction_formula, data)
interaction_model <- step(interaction_full, scope = list(lower = formula(model),
  upper = interaction_formula), direction = "backward", trace = 0)
write.csv(data.frame(model = c("Selected main effects", "Exploratory interactions"),
  p = c(model$rank, interaction_model$rank),
  AIC = c(AIC(model), AIC(interaction_model)), BIC = c(BIC(model), BIC(interaction_model))),
  "results/exploratory_interactions.csv", row.names = FALSE)

png("figures/regression_diagnostics.png", width = 1600, height = 1200, res = 160)
par(mfrow = c(2, 2)); plot(model); dev.off()
png("figures/cv_predictions.png", width = 1100, height = 900, res = 150)
d <- pred[pred$model == "BIC_selected", ]
plot(d$actual_log_price, d$predicted_log_price, pch = 16, cex = 0.6, col = "#28658088",
  xlab = "Observed log-price", ylab = "Out-of-fold predicted log-price",
  main = "Nine-fold validation: BIC selection within training folds")
abline(0, 1, col = "#AE5838", lwd = 2); dev.off()
png("figures/model_selection.png", width = 1100, height = 800, res = 150)
t <- selection$table
plot(t$p, t$BIC, pch = 16, cex = 0.5, col = "#28658055", xlab = "Regression coefficients (including intercept)",
     ylab = "BIC", main = "Exhaustive main-effect model comparison")
points(model$rank, BIC(model), pch = 19, col = "#AE5838", cex = 1.5); dev.off()

# Box-Cox is an exploratory full-data diagnostic. Log-price was fixed before
# validation; this profile is not used to tune the validated response scale.
X <- model.matrix(full)
lambda <- seq(-1, 1, by = 0.01)
profile <- vapply(lambda, function(l) {
  transformed <- if (abs(l) < 1e-8) log(data$Y) else expm1(l * log(data$Y)) / l
  rss <- sum(lm.fit(X, transformed)$residuals^2)
  -n / 2 * log(rss / n) + (l - 1) * sum(log(data$Y))
}, numeric(1))
write.csv(data.frame(lambda = lambda, log_likelihood_relative = profile - max(profile)),
          "results/box_cox_profile.csv", row.names = FALSE)
png("figures/box_cox.png", width = 1100, height = 800, res = 150)
plot(lambda, profile - max(profile), type = "l", lwd = 2, col = "#286580",
  xlab = expression(lambda), ylab = "Profile log-likelihood relative to maximum",
  main = "Exploratory Box-Cox profile: full categorical model")
abline(h = -qchisq(0.95, 1) / 2, lty = 2, col = "#777777")
abline(v = 0, col = "#AE5838", lty = 2); dev.off()
raw_model <- lm(update(formula(full), Y ~ .), data)
png("figures/response_transformation.png", width = 1500, height = 750, res = 150)
par(mfrow = c(1, 2))
plot(fitted(raw_model), resid(raw_model), pch = 16, cex = 0.5, col = "#28658088",
  xlab = "Fitted sale price (dollars)", ylab = "Residual (dollars)", main = "Raw-price response")
abline(h = 0, col = "#AE5838")
plot(fitted(full), resid(full), pch = 16, cex = 0.5, col = "#28658088",
  xlab = "Fitted log-price", ylab = "Residual (log-price)", main = "Log-price response")
abline(h = 0, col = "#AE5838"); dev.off()

capture.output({
  cat("Selected main-effect model\n"); print(formula(model)); print(summary(model))
  cat("\nFull-model comparison (exploratory post-selection)\n"); print(anova(model, full))
  cat("\nModel-selection winners\n")
  print(selection$table[which.min(selection$table$AIC), ])
  print(selection$table[which.min(selection$table$BIC), ])
  print(selection$table[which.min(selection$table$PRESS), ])
  cat("\nCross-validation of entire BIC selection procedure\n"); print(metrics)
  cat("\nDiagnostic flag counts\n")
  print(colSums(diagnostics[, c("leverage_flag", "DFFITS_flag", "DFBETAS_flag")]))
  cat("\nBonferroni residual flags\n"); print(data$case_id[diagnostics$bonferroni_p < 0.05])
  cat("\nExploratory interaction model\n"); print(formula(interaction_model))
  cat("\nSession information\n"); print(sessionInfo())
}, file = "results/analysis_summary.txt")
cat("Complete. Results and figures regenerated.\n")
