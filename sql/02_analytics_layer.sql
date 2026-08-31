/* =============================================================================
   Analytics layer -- views and procs a portfolio / servicing analyst queries
   -----------------------------------------------------------------------------
     mtg.vPortfolioMonthly     UPB, WAC, WAM, WA FICO/LTV, serious-DQ % by month
     mtg.vStratification       latest-month book sliced by FICO / LTV / state / ...
     mtg.vDelinquencyMonthly   loan & UPB counts by delinquency bucket by month
     mtg.vVintagePerformance   cumulative default / prepay / active % by age & vintage
     mtg.vPrepaymentSpeed      monthly SMM and annualised CPR
     mtg.vExpectedLoss         CECL-style PD x LGD x EAD reserve by segment
     mtg.uspRollRateMatrix     month-to-month delinquency transition matrix

   Idempotent (CREATE OR ALTER).  Run:  .\q.ps1 -File sql\02_analytics_layer.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mtg.vPortfolioMonthly AS
SELECT
    lp.AsOfMonth,
    ActiveLoans   = COUNT(*),
    UPB           = CAST(SUM(lp.ActualUPB) AS decimal(16,2)),
    WAC           = CAST(SUM(lp.ActualUPB * l.NoteRate)    / SUM(lp.ActualUPB) AS decimal(6,4)),
    WAM_Months    = CAST(SUM(lp.ActualUPB * lp.RemainingTermMonths) / SUM(lp.ActualUPB) AS decimal(6,1)),
    WA_FICO       = CAST(SUM(lp.ActualUPB * l.CreditScore) / SUM(lp.ActualUPB) AS decimal(6,1)),
    WA_OriginalLTV = CAST(SUM(lp.ActualUPB * l.OriginalLTV) / SUM(lp.ActualUPB) AS decimal(5,2)),
    SeriousDQ_PctUPB = CAST(100.0 * SUM(CASE WHEN lp.DelinquencyStatus IN ('90','120','FC') THEN lp.ActualUPB ELSE 0 END)
                                  / SUM(lp.ActualUPB) AS decimal(5,2))
FROM mtg.LoanPerformance lp
JOIN mtg.Loan l ON l.LoanId = lp.LoanId
WHERE lp.ActualUPB > 0
GROUP BY lp.AsOfMonth;
GO

/* ---------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mtg.vStratification AS
WITH latest AS (
    SELECT lp.LoanId, lp.ActualUPB, l.NoteRate, l.CreditScore, l.OriginalLTV,
           l.PropertyState, l.LoanPurpose, l.Occupancy, l.Channel,
           VintageYear = YEAR(l.OriginationDate)
    FROM mtg.LoanPerformance lp
    JOIN mtg.Loan l ON l.LoanId = lp.LoanId
    WHERE lp.AsOfMonth = (SELECT MAX(AsOfMonth) FROM mtg.LoanPerformance)
      AND lp.ActualUPB > 0
),
sliced AS (
    SELECT 'FICO band' AS Dimension,
           CASE WHEN CreditScore < 620 THEN '1. <620'
                WHEN CreditScore < 660 THEN '2. 620-659'
                WHEN CreditScore < 700 THEN '3. 660-699'
                WHEN CreditScore < 740 THEN '4. 700-739'
                WHEN CreditScore < 780 THEN '5. 740-779'
                ELSE '6. 780+' END AS Bucket,
           ActualUPB, NoteRate FROM latest
    UNION ALL
    SELECT 'Original LTV',
           CASE WHEN OriginalLTV <= 60 THEN '1. <=60'
                WHEN OriginalLTV <= 70 THEN '2. 60-70'
                WHEN OriginalLTV <= 80 THEN '3. 70-80'
                WHEN OriginalLTV <= 90 THEN '4. 80-90'
                ELSE '5. 90+' END,
           ActualUPB, NoteRate FROM latest
    UNION ALL
    SELECT 'Loan purpose', LoanPurpose, ActualUPB, NoteRate FROM latest
    UNION ALL
    SELECT 'Occupancy', Occupancy, ActualUPB, NoteRate FROM latest
    UNION ALL
    SELECT 'Origination channel', Channel, ActualUPB, NoteRate FROM latest
    UNION ALL
    SELECT 'Vintage year', CAST(VintageYear AS varchar(4)), ActualUPB, NoteRate FROM latest
    UNION ALL
    SELECT 'Property state (top)', PropertyState, ActualUPB, NoteRate FROM latest
)
SELECT
    Dimension,
    Bucket,
    Loans    = COUNT(*),
    UPB      = CAST(SUM(ActualUPB) AS decimal(16,2)),
    PctUPB   = CAST(100.0 * SUM(ActualUPB) / SUM(SUM(ActualUPB)) OVER (PARTITION BY Dimension) AS decimal(5,1)),
    WA_Rate  = CAST(SUM(ActualUPB * NoteRate) / SUM(ActualUPB) AS decimal(6,4))
FROM sliced
GROUP BY Dimension, Bucket;
GO

/* ---------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mtg.vDelinquencyMonthly AS
SELECT
    AsOfMonth,
    DelinquencyStatus,
    Loans = COUNT(*),
    UPB   = CAST(SUM(ActualUPB) AS decimal(16,2))
FROM mtg.LoanPerformance
WHERE ActualUPB > 0
GROUP BY AsOfMonth, DelinquencyStatus;
GO

/* ---------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mtg.vVintagePerformance AS
WITH evt AS (
    SELECT lp.LoanId,
           PrepaidAge = MIN(CASE WHEN lp.ZeroBalanceCode = '01' THEN lp.LoanAge END),
           DefaultAge = MIN(CASE WHEN lp.ZeroBalanceCode = '09' THEN lp.LoanAge END),
           MaxAge     = MAX(lp.LoanAge)
    FROM mtg.LoanPerformance lp
    GROUP BY lp.LoanId
),
loan AS (
    SELECT l.LoanId, VintageYear = YEAR(l.OriginationDate), l.OriginalBalance,
           e.PrepaidAge, e.DefaultAge, e.MaxAge
    FROM mtg.Loan l JOIN evt e ON e.LoanId = l.LoanId
),
vmax AS (
    SELECT VintageYear, MaxObsAge = MAX(MaxAge) FROM loan GROUP BY VintageYear
),
ages AS (
    SELECT value AS Age FROM GENERATE_SERIES(1, (SELECT MAX(MaxObsAge) FROM vmax))
)
SELECT
    v.VintageYear,
    a.Age,
    LoansInCohort  = COUNT(*),
    OriginalUPB    = CAST(SUM(v.OriginalBalance) AS decimal(18,2)),
    CumDefault_Pct = CAST(100.0 * SUM(CASE WHEN v.DefaultAge <= a.Age THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,2)),
    CumPrepay_Pct  = CAST(100.0 * SUM(CASE WHEN v.PrepaidAge <= a.Age THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,2)),
    Active_Pct     = CAST(100.0 * SUM(CASE WHEN (v.DefaultAge IS NULL OR v.DefaultAge > a.Age)
                                            AND (v.PrepaidAge IS NULL OR v.PrepaidAge > a.Age)
                                            AND v.MaxAge >= a.Age THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,2))
FROM loan v
JOIN vmax vm ON vm.VintageYear = v.VintageYear
JOIN ages a  ON a.Age <= vm.MaxObsAge
GROUP BY v.VintageYear, a.Age;
GO

/* ---------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mtg.vPrepaymentSpeed AS
SELECT
    AsOfMonth,
    ScheduledBeginUPB    = CAST(SUM(ScheduledBalance + ScheduledPrincipal) AS decimal(18,2)),
    UnscheduledPrincipal = CAST(SUM(UnscheduledPrincipal) AS decimal(18,2)),
    SMM_Pct = CAST(100.0 * SUM(UnscheduledPrincipal) / NULLIF(SUM(ScheduledBalance + ScheduledPrincipal), 0) AS decimal(6,3)),
    CPR_Pct = CAST(100.0 * (1 - POWER(1 - SUM(UnscheduledPrincipal) / NULLIF(SUM(ScheduledBalance + ScheduledPrincipal), 0), 12.0)) AS decimal(6,2))
FROM mtg.LoanPerformance
GROUP BY AsOfMonth;
GO

/* ---------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mtg.vExpectedLoss AS
WITH latest AS (
    SELECT lp.LoanId, lp.DelinquencyStatus, lp.ActualUPB, l.OriginalLTV
    FROM mtg.LoanPerformance lp
    JOIN mtg.Loan l ON l.LoanId = lp.LoanId
    WHERE lp.AsOfMonth = (SELECT MAX(AsOfMonth) FROM mtg.LoanPerformance)
      AND lp.ActualUPB > 0
)
SELECT
    Segment      = latest.DelinquencyStatus,
    Loans        = COUNT(*),
    EAD_UPB      = CAST(SUM(latest.ActualUPB) AS decimal(16,2)),
    PD           = MAX(pd.PD),
    WA_LGD       = CAST(SUM(lgd.LGD * latest.ActualUPB) / SUM(latest.ActualUPB) AS decimal(5,3)),
    ExpectedLoss = CAST(SUM(pd.PD * lgd.LGD * latest.ActualUPB) AS decimal(16,2)),
    LossRate_Pct = CAST(100.0 * SUM(pd.PD * lgd.LGD * latest.ActualUPB) / SUM(latest.ActualUPB) AS decimal(6,3))
FROM latest
JOIN mtg.PDAssumption pd ON pd.Segment = latest.DelinquencyStatus
CROSS APPLY (SELECT LGD = CASE WHEN latest.OriginalLTV <= 60 THEN 0.10
                              WHEN latest.OriginalLTV <= 80 THEN 0.20
                              WHEN latest.OriginalLTV <= 90 THEN 0.30
                              ELSE 0.40 END) lgd
GROUP BY latest.DelinquencyStatus;
GO

/* ----------------------------------------------------------------------------
   Roll-rate matrix: for loans on the books in @AsOfMonth, where did each
   delinquency bucket go one month later? Rows = starting bucket; columns =
   ending bucket (incl. PaidOff / Liquidated); cells = % of the starting
   bucket's UPB. The diagonal is "stayed put"; below it is curing, above is
   rolling forward.
   ---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE mtg.uspRollRateMatrix
    @AsOfMonth date
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH cur AS (
        SELECT LoanId, DelinquencyStatus, ActualUPB
        FROM mtg.LoanPerformance
        WHERE AsOfMonth = @AsOfMonth AND ActualUPB > 0
    ),
    nxt AS (
        SELECT LoanId, DelinquencyStatus, ZeroBalanceCode
        FROM mtg.LoanPerformance
        WHERE AsOfMonth = DATEADD(MONTH, 1, @AsOfMonth)
    ),
    moves AS (
        SELECT
            cur.DelinquencyStatus AS FromBucket,
            cur.ActualUPB,
            ToBucket = CASE
                WHEN nxt.LoanId IS NULL           THEN 'NoData'
                WHEN nxt.ZeroBalanceCode = '01'   THEN 'PaidOff'
                WHEN nxt.ZeroBalanceCode = '09'   THEN 'Liquidated'
                ELSE nxt.DelinquencyStatus END
        FROM cur
        LEFT JOIN nxt ON nxt.LoanId = cur.LoanId
    )
    SELECT
        FromBucket,
        Loans      = COUNT(*),
        BeginUPB   = CAST(SUM(ActualUPB) AS decimal(16,2)),
        [%->C]          = CAST(100.0 * SUM(CASE WHEN ToBucket = 'C'          THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1)),
        [%->30]         = CAST(100.0 * SUM(CASE WHEN ToBucket = '30'         THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1)),
        [%->60]         = CAST(100.0 * SUM(CASE WHEN ToBucket = '60'         THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1)),
        [%->90]         = CAST(100.0 * SUM(CASE WHEN ToBucket = '90'         THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1)),
        [%->120]        = CAST(100.0 * SUM(CASE WHEN ToBucket = '120'        THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1)),
        [%->FC]         = CAST(100.0 * SUM(CASE WHEN ToBucket = 'FC'         THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1)),
        [%->PaidOff]    = CAST(100.0 * SUM(CASE WHEN ToBucket = 'PaidOff'    THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1)),
        [%->Liquidated] = CAST(100.0 * SUM(CASE WHEN ToBucket = 'Liquidated' THEN ActualUPB ELSE 0 END) / SUM(ActualUPB) AS decimal(5,1))
    FROM moves
    WHERE ToBucket <> 'NoData'
    GROUP BY FromBucket
    ORDER BY CASE FromBucket WHEN 'C' THEN 0 WHEN '30' THEN 1 WHEN '60' THEN 2
                             WHEN '90' THEN 3 WHEN '120' THEN 4 WHEN 'FC' THEN 5 ELSE 9 END;
END;
GO

PRINT 'Analytics layer built.';
GO
