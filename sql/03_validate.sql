/* =============================================================================
   Validate the generated portfolio -- data-quality / reconciliation checks
   -----------------------------------------------------------------------------
   One result set: Check | Detail | Status. Every row should read PASS.

   Run:  .\q.ps1 -File sql\03_validate.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

;WITH
closed AS (   -- closed-form amortized balance at each row's LoanAge
    SELECT lp.LoanAge, l.TermMonths, lp.ScheduledBalance,
           ClosedBal = l.OriginalBalance * POWER(1 + i, lp.LoanAge)
                     - l.MonthlyPI * (POWER(1 + i, lp.LoanAge) - 1) / i
    FROM mtg.LoanPerformance lp
    JOIN mtg.Loan l ON l.LoanId = lp.LoanId
    CROSS APPLY (SELECT i = CAST(l.NoteRate AS float) / 12.0) k
),
term_bal AS (   -- closed-form balance at full term, per loan (should be ~0)
    SELECT l.LoanId,
           EndBalPctOfOrig = ABS(l.OriginalBalance * POWER(1 + i, l.TermMonths)
                  - l.MonthlyPI * (POWER(1 + i, l.TermMonths) - 1) / i) / l.OriginalBalance
    FROM mtg.Loan l
    CROSS APPLY (SELECT i = CAST(l.NoteRate AS float) / 12.0) k
),
contiguity AS (
    SELECT LoanId, Rows = COUNT(*), MinAge = MIN(LoanAge), MaxAge = MAX(LoanAge)
    FROM mtg.LoanPerformance GROUP BY LoanId
),
zb AS (
    SELECT lp.LoanId, f.EventType,
           ZbRows   = SUM(CASE WHEN lp.ZeroBalanceCode IS NOT NULL THEN 1 ELSE 0 END),
           ZbNotLast = SUM(CASE WHEN lp.ZeroBalanceCode IS NOT NULL AND lp.LoanAge <> f.EventAge THEN 1 ELSE 0 END),
           ZbNonZeroUPB = SUM(CASE WHEN lp.ZeroBalanceCode IS NOT NULL AND lp.ActualUPB <> 0 THEN 1 ELSE 0 END)
    FROM mtg.LoanPerformance lp
    JOIN mtg.LoanFate f ON f.LoanId = lp.LoanId
    GROUP BY lp.LoanId, f.EventType
),
checks AS (
    SELECT 1 AS Seq,
           'ScheduledBalance = closed-form amortization' AS [Check],
           CONCAT('max abs diff = $', FORMAT((SELECT MAX(ABS(ScheduledBalance - ClosedBal))
                                              FROM closed WHERE LoanAge < TermMonths - 1), 'N4')) AS Detail,
           CASE WHEN (SELECT MAX(ABS(ScheduledBalance - ClosedBal))
                      FROM closed WHERE LoanAge < TermMonths - 1) < 0.05 THEN 'PASS' ELSE '*** FAIL ***' END AS Status
    UNION ALL
    SELECT 2, 'Loan fully amortizes to ~0 at term',
           CONCAT('max residual = ', FORMAT((SELECT MAX(EndBalPctOfOrig) FROM term_bal), 'P4'), ' of original balance'),
           CASE WHEN (SELECT MAX(EndBalPctOfOrig) FROM term_bal) < 0.001 THEN 'PASS' ELSE '*** FAIL ***' END
    UNION ALL
    SELECT 3, 'ActualUPB within [0, OriginalBalance]',
           CONCAT((SELECT COUNT(*) FROM mtg.LoanPerformance lp JOIN mtg.Loan l ON l.LoanId = lp.LoanId
                   WHERE lp.ActualUPB < 0 OR lp.ActualUPB > l.OriginalBalance), ' offending rows'),
           CASE WHEN (SELECT COUNT(*) FROM mtg.LoanPerformance lp JOIN mtg.Loan l ON l.LoanId = lp.LoanId
                      WHERE lp.ActualUPB < 0 OR lp.ActualUPB > l.OriginalBalance) = 0 THEN 'PASS' ELSE '*** FAIL ***' END
    UNION ALL
    SELECT 4, 'Performance history is contiguous (age 1..N, no gaps)',
           CONCAT((SELECT COUNT(*) FROM contiguity WHERE Rows <> MaxAge OR MinAge <> 1), ' loans with gaps'),
           CASE WHEN (SELECT COUNT(*) FROM contiguity WHERE Rows <> MaxAge OR MinAge <> 1) = 0 THEN 'PASS' ELSE '*** FAIL ***' END
    UNION ALL
    SELECT 5, 'Zero-balance row: exactly one, last month, UPB = 0 (terminated loans only)',
           CONCAT((SELECT COUNT(*) FROM zb
                   WHERE (EventType IN ('Prepaid','Default') AND (ZbRows <> 1 OR ZbNotLast > 0 OR ZbNonZeroUPB > 0))
                      OR (EventType = 'Active' AND ZbRows <> 0)), ' loans violating'),
           CASE WHEN (SELECT COUNT(*) FROM zb
                      WHERE (EventType IN ('Prepaid','Default') AND (ZbRows <> 1 OR ZbNotLast > 0 OR ZbNonZeroUPB > 0))
                         OR (EventType = 'Active' AND ZbRows <> 0)) = 0 THEN 'PASS' ELSE '*** FAIL ***' END
    UNION ALL
    SELECT 6, 'DelinquencyStatus in {C,30,60,90,120,FC} and DaysPastDue consistent',
           CONCAT((SELECT COUNT(*) FROM mtg.LoanPerformance
                   WHERE DelinquencyStatus NOT IN ('C','30','60','90','120','FC')
                      OR DaysPastDue <> CASE DelinquencyStatus WHEN 'C' THEN 0 WHEN '30' THEN 30 WHEN '60' THEN 60
                                             WHEN '90' THEN 90 WHEN '120' THEN 120 ELSE 150 END), ' bad rows'),
           CASE WHEN (SELECT COUNT(*) FROM mtg.LoanPerformance
                      WHERE DelinquencyStatus NOT IN ('C','30','60','90','120','FC')
                         OR DaysPastDue <> CASE DelinquencyStatus WHEN 'C' THEN 0 WHEN '30' THEN 30 WHEN '60' THEN 60
                                                WHEN '90' THEN 90 WHEN '120' THEN 120 ELSE 150 END) = 0 THEN 'PASS' ELSE '*** FAIL ***' END
    UNION ALL
    SELECT 7, 'Portfolio-level sanity (WAC 3-9%, serious DQ < 3% of UPB)',
           (SELECT CONCAT('WAC = ', FORMAT(WAC, 'P2'), ', serious DQ = ', FORMAT(SeriousDQ_PctUPB / 100.0, 'P2'))
            FROM mtg.vPortfolioMonthly WHERE AsOfMonth = (SELECT MAX(AsOfMonth) FROM mtg.vPortfolioMonthly)),
           (SELECT CASE WHEN WAC BETWEEN 0.03 AND 0.09 AND SeriousDQ_PctUPB < 3 THEN 'PASS' ELSE '*** FAIL ***' END
            FROM mtg.vPortfolioMonthly WHERE AsOfMonth = (SELECT MAX(AsOfMonth) FROM mtg.vPortfolioMonthly))
)
SELECT [Check], Detail, Status FROM checks ORDER BY Seq;
GO
