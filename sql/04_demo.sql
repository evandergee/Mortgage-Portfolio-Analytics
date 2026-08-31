/* =============================================================================
   Guided tour of the analytics layer
   Run:  .\q.ps1 -File sql\04_demo.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

PRINT '========== 1. Portfolio snapshot -- most recent month ==========';
SELECT TOP 1 AsOfMonth, ActiveLoans, UPB, WAC, WAM_Months, WA_FICO, WA_OriginalLTV, SeriousDQ_PctUPB
FROM mtg.vPortfolioMonthly ORDER BY AsOfMonth DESC;

PRINT '========== 2. Portfolio trend -- last 12 months ==========';
SELECT TOP 12 AsOfMonth, ActiveLoans, UPB, WAC, SeriousDQ_PctUPB
FROM mtg.vPortfolioMonthly ORDER BY AsOfMonth DESC;

PRINT '========== 3. Stratification -- by FICO band and by vintage ==========';
SELECT Dimension, Bucket, Loans, UPB, PctUPB, WA_Rate
FROM mtg.vStratification
WHERE Dimension IN ('FICO band', 'Vintage year')
ORDER BY Dimension, Bucket;

PRINT '========== 4. Amortization schedule for loan 1 (recursive CTE) ==========';
IF OBJECT_ID('tempdb..#amort') IS NOT NULL DROP TABLE #amort;
CREATE TABLE #amort (PaymentNo int, PaymentDate date, BeginningBalance decimal(14,2),
                     Interest decimal(14,2), Principal decimal(14,2), EndingBalance decimal(14,2));
INSERT #amort EXEC mtg.uspAmortizationSchedule @LoanId = 1;
SELECT l.LoanId, l.OriginalBalance, l.NoteRate, l.TermMonths, l.MonthlyPI FROM mtg.Loan l WHERE l.LoanId = 1;
PRINT ' -- first 6 payments:';
SELECT TOP 6 * FROM #amort ORDER BY PaymentNo;
PRINT ' -- last 6 payments:';
SELECT TOP 6 * FROM #amort ORDER BY PaymentNo DESC;

PRINT '========== 5. Delinquency distribution -- most recent month ==========';
SELECT DelinquencyStatus, Loans, UPB,
       PctOfUPB = CAST(100.0 * UPB / SUM(UPB) OVER () AS decimal(6,3))
FROM mtg.vDelinquencyMonthly
WHERE AsOfMonth = (SELECT MAX(AsOfMonth) FROM mtg.vDelinquencyMonthly)
ORDER BY CASE DelinquencyStatus WHEN 'C' THEN 0 WHEN '30' THEN 1 WHEN '60' THEN 2
                                WHEN '90' THEN 3 WHEN '120' THEN 4 ELSE 5 END;

PRINT '========== 6. Roll-rate matrix -- June 2024 to July 2024 (% of begin UPB) ==========';
EXEC mtg.uspRollRateMatrix @AsOfMonth = '2024-06-01';

PRINT '========== 7. Vintage curve -- cumulative default % at ages 12 / 24 / 36 / 48 ==========';
SELECT VintageYear,
       [12] = MAX(CASE WHEN Age = 12 THEN CumDefault_Pct END),
       [24] = MAX(CASE WHEN Age = 24 THEN CumDefault_Pct END),
       [36] = MAX(CASE WHEN Age = 36 THEN CumDefault_Pct END),
       [48] = MAX(CASE WHEN Age = 48 THEN CumDefault_Pct END)
FROM mtg.vVintagePerformance
GROUP BY VintageYear ORDER BY VintageYear;

PRINT '========== 8. Prepayment speed (annualised CPR) -- last 12 months ==========';
SELECT TOP 12 AsOfMonth, ScheduledBeginUPB, UnscheduledPrincipal, SMM_Pct, CPR_Pct
FROM mtg.vPrepaymentSpeed ORDER BY AsOfMonth DESC;

PRINT '========== 9. Expected loss (CECL-style) -- by delinquency segment ==========';
SELECT Segment, Loans, EAD_UPB, PD, WA_LGD, ExpectedLoss, LossRate_Pct
FROM mtg.vExpectedLoss
ORDER BY CASE Segment WHEN 'C' THEN 0 WHEN '30' THEN 1 WHEN '60' THEN 2
                      WHEN '90' THEN 3 WHEN '120' THEN 4 ELSE 5 END;
SELECT PortfolioExpectedLoss = SUM(ExpectedLoss),
       PortfolioUPB = SUM(EAD_UPB),
       ReserveRate_Pct = CAST(100.0 * SUM(ExpectedLoss) / SUM(EAD_UPB) AS decimal(6,3))
FROM mtg.vExpectedLoss;
GO
