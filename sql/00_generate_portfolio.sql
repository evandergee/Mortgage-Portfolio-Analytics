/* =============================================================================
   Mortgage portfolio analytics -- synthetic data generator
   -----------------------------------------------------------------------------
   There is no free "Chinook" for mortgage servicing, so this script builds one:
   a `mtg` schema with a loan book and a monthly performance history in the
   layout of a Fannie Mae / Freddie Mac loan-level performance file.

       mtg.Loan             ~4,000 first-lien loans, originated 2019-01 .. 2025-06
       mtg.LoanPerformance  one row per loan per month it was on the books
       mtg.LoanFate         synthetic-data driver only (NOT part of the model)

   Scheduled balances are the closed-form amortization value
        B_k = P*(1+i)^k - PMT*((1+i)^k - 1)/i
   Each loan is assigned a "fate": prepay (~45%), default (~6%), or still active.
   A defaulting loan ramps 30 -> 60 -> 90 -> 120 -> FC in the 5 months before it
   liquidates; ~30% of the rest have a 1-3 month transient delinquency episode
   that then cures back to Current (dialled up from a real prime book so the
   roll-rate matrix has something to show).

   Set-based, no loops. Idempotent. Run:
       .\q.ps1 -File sql\00_generate_portfolio.sql        (~1 min)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF SCHEMA_ID('mtg') IS NULL EXEC('CREATE SCHEMA mtg');
GO

DROP TABLE IF EXISTS mtg.LoanPerformance;
DROP TABLE IF EXISTS mtg.LoanFate;
DROP TABLE IF EXISTS mtg.Loan;
DROP TABLE IF EXISTS mtg.PDAssumption;
GO

CREATE TABLE mtg.Loan (
    LoanId           int           NOT NULL CONSTRAINT PK_mtg_Loan PRIMARY KEY,
    OriginationDate  date          NOT NULL,
    FirstPaymentDate date          NOT NULL,
    OriginalBalance  decimal(12,2) NOT NULL,
    NoteRate         decimal(6,4)  NOT NULL,      -- annual, e.g. 0.0675
    TermMonths       int           NOT NULL,
    MonthlyPI        decimal(12,2) NOT NULL,      -- principal & interest payment
    OriginalLTV      decimal(5,2)  NOT NULL,
    DTI              decimal(5,2)  NOT NULL,
    CreditScore      int           NOT NULL,      -- FICO at origination
    PropertyState    char(2)       NOT NULL,
    PropertyType     varchar(20)   NOT NULL,
    Occupancy        varchar(12)   NOT NULL,
    LoanPurpose      varchar(14)   NOT NULL,
    Channel          varchar(14)   NOT NULL
);
GO

/* ---- origination book ------------------------------------------------------- */
;WITH r AS (
    SELECT
        v.value AS LoanId,
        ABS(CHECKSUM(NEWID())) AS r1,  ABS(CHECKSUM(NEWID())) AS r2,
        ABS(CHECKSUM(NEWID())) AS r3,  ABS(CHECKSUM(NEWID())) AS r4,
        ABS(CHECKSUM(NEWID())) AS r5,  ABS(CHECKSUM(NEWID())) AS r6,
        ABS(CHECKSUM(NEWID())) AS r7,  ABS(CHECKSUM(NEWID())) AS r8,
        ABS(CHECKSUM(NEWID())) AS r9
    FROM GENERATE_SERIES(1, 4000) AS v
),
d AS (
    SELECT
        LoanId,
        OriginationDate = DATEADD(DAY, r2 % 27, DATEADD(MONTH, r1 % 78, CAST('2019-01-01' AS date))),
        OriginalBalance = CAST(125000 + (r3 % 550) * 1000 AS decimal(12,2)),
        TermMonths      = CASE WHEN r4 % 10 < 8 THEN 360 ELSE 180 END,
        CreditScore     = CASE WHEN r5 % 100 < 4 THEN 585 + (r5 % 35) ELSE 620 + (r5 % 200) END,
        OriginalLTV     = CAST(CASE WHEN r6 % 100 < 28 THEN 80.0 ELSE 45 + (r6 % 51) END AS decimal(5,2)),
        DTI             = CAST(22 + (r7 % 27) AS decimal(5,2)),
        PropertyState   = CONVERT(char(2), CHOOSE(r8 % 15 + 1, 'CA','TX','FL','NY','CA','TX','FL','PA','IL','OH','GA','NC','MI','WA','AZ')),
        PropertyType    = CHOOSE(r9 % 8 + 1, 'SingleFamily','SingleFamily','SingleFamily','SingleFamily','Condo','Condo','PUD','TwoToFourFamily'),
        Occupancy       = CASE WHEN r1 % 10 < 8 THEN 'Primary' WHEN r1 % 10 < 9 THEN 'Investor' ELSE 'SecondHome' END,
        LoanPurpose     = CASE WHEN r2 % 10 < 5 THEN 'Purchase' WHEN r2 % 10 < 8 THEN 'RateTermRefi' ELSE 'CashOutRefi' END,
        Channel         = CASE WHEN r3 % 10 < 6 THEN 'Retail' WHEN r3 % 10 < 9 THEN 'Broker' ELSE 'Correspondent' END,
        rNoise = r7
    FROM r
),
p AS (
    SELECT *,
        NoteRate = CAST(
            CASE YEAR(OriginationDate)
                 WHEN 2019 THEN 0.0445 WHEN 2020 THEN 0.0335 WHEN 2021 THEN 0.0300
                 WHEN 2022 THEN 0.0510 WHEN 2023 THEN 0.0672 WHEN 2024 THEN 0.0705
                 ELSE 0.0655 END
            + (rNoise % 110) / 10000.0
            + CASE WHEN CreditScore < 660 THEN 0.0035 ELSE 0 END
            AS decimal(6,4)),
        FirstPaymentDate = DATEADD(MONTH, 2, DATEFROMPARTS(YEAR(OriginationDate), MONTH(OriginationDate), 1))
    FROM d
)
INSERT mtg.Loan (LoanId, OriginationDate, FirstPaymentDate, OriginalBalance, NoteRate, TermMonths,
                 MonthlyPI, OriginalLTV, DTI, CreditScore, PropertyState, PropertyType,
                 Occupancy, LoanPurpose, Channel)
SELECT
    LoanId, OriginationDate, FirstPaymentDate, OriginalBalance, NoteRate, TermMonths,
    CAST(OriginalBalance * (CAST(NoteRate AS float)/12.0)
         / (1 - POWER(1e0 + CAST(NoteRate AS float)/12.0, -TermMonths)) AS decimal(12,2)),
    OriginalLTV, DTI, CreditScore, PropertyState, PropertyType, Occupancy, LoanPurpose, Channel
FROM p;
PRINT CONCAT('mtg.Loan            : ', @@ROWCOUNT, ' loans');
GO

/* ---- each loan's fate (synthetic-data driver, not a real servicing field) --- */
DECLARE @Today date = '2026-08-01';

CREATE TABLE mtg.LoanFate (
    LoanId    int NOT NULL CONSTRAINT PK_mtg_LoanFate PRIMARY KEY,
    EventAge  int NOT NULL,          -- loan age (months) at the terminating event / last obs
    EventType varchar(8) NOT NULL,   -- 'Prepaid' | 'Default' | 'Active'
    BlipAge   int NULL,              -- start age of a transient delinquency episode, else NULL
    BlipLen   int NULL               -- episode length in months (1 -> 30dpd, 2 -> 30/60, ...)
);

;WITH f AS (
    SELECT
        l.LoanId, l.TermMonths,
        MaxAge = DATEDIFF(MONTH, l.FirstPaymentDate, @Today) + 1,
        h1 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('p', l.LoanId)))),
        h2 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('d', l.LoanId)))),
        h3 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('b', l.LoanId)))),
        h4 = ABS(CHECKSUM(HASHBYTES('MD5', CONCAT('L', l.LoanId))))
    FROM mtg.Loan l
),
g AS (
    SELECT *,
        PrepayAge  = CASE WHEN h1 % 100 < 45 THEN 6 + (h1 % 170) END,
        DefaultAge = CASE WHEN h2 % 100 < 6  THEN 10 + (h2 % 88) END
    FROM f
),
h AS (
    SELECT LoanId, TermMonths, MaxAge, h3, h4,
        EventAge = LEAST(ISNULL(PrepayAge, 999999), ISNULL(DefaultAge, 999999), MaxAge, TermMonths),
        PrepayAge, DefaultAge
    FROM g
)
INSERT mtg.LoanFate (LoanId, EventAge, EventType, BlipAge, BlipLen)
SELECT
    LoanId,
    EventAge,
    CASE WHEN ISNULL(DefaultAge, 999999) = EventAge THEN 'Default'
         WHEN ISNULL(PrepayAge,  999999) = EventAge THEN 'Prepaid'
         ELSE 'Active' END,
    CASE WHEN h3 % 100 < 30 AND EventAge > 6 THEN 4 + (h3 % (EventAge - 4)) END,
    CASE WHEN h3 % 100 < 30 AND EventAge > 6
         THEN CASE WHEN h4 % 10 < 6 THEN 1 WHEN h4 % 10 < 9 THEN 2 ELSE 3 END END
FROM h;
PRINT CONCAT('mtg.LoanFate        : ', @@ROWCOUNT, ' (prepaid/default/active split below)');
GO

/* ---- monthly performance history ------------------------------------------- */
CREATE TABLE mtg.LoanPerformance (
    LoanId               int           NOT NULL,
    AsOfMonth            date          NOT NULL,
    LoanAge              int           NOT NULL,
    RemainingTermMonths  int           NOT NULL,
    ScheduledPrincipal   decimal(12,2) NOT NULL,
    ScheduledInterest    decimal(12,2) NOT NULL,
    ScheduledBalance     decimal(12,2) NOT NULL,   -- closed-form amortized UPB
    ActualUPB            decimal(12,2) NOT NULL,   -- 0 in the zero-balance month
    UnscheduledPrincipal decimal(12,2) NOT NULL,   -- prepayment / payoff principal
    DelinquencyStatus    varchar(3)    NOT NULL,   -- C, 30, 60, 90, 120, FC
    DaysPastDue          int           NOT NULL,
    ZeroBalanceCode      varchar(2)    NULL,       -- 01 = prepaid, 09 = default liquidation
    ZeroBalanceDate      date          NULL,
    CONSTRAINT PK_mtg_LoanPerformance PRIMARY KEY (LoanId, AsOfMonth)
);
GO

;WITH lp AS (
    SELECT l.LoanId, l.OriginalBalance, l.MonthlyPI, l.TermMonths, l.FirstPaymentDate,
           f.EventAge, f.EventType, f.BlipAge, f.BlipLen,
           i = CAST(l.NoteRate AS float) / 12.0
    FROM mtg.Loan l
    JOIN mtg.LoanFate f ON f.LoanId = l.LoanId
)
INSERT mtg.LoanPerformance (LoanId, AsOfMonth, LoanAge, RemainingTermMonths,
    ScheduledPrincipal, ScheduledInterest, ScheduledBalance, ActualUPB, UnscheduledPrincipal,
    DelinquencyStatus, DaysPastDue, ZeroBalanceCode, ZeroBalanceDate)
SELECT
    lp.LoanId,
    m.AsOfMonth,
    a.value AS LoanAge,
    lp.TermMonths - a.value,
    CAST(c.schedPrin AS decimal(12,2)),
    CAST(c.schedInt  AS decimal(12,2)),
    CAST(e.endBal    AS decimal(12,2)),
    CASE WHEN z.isZB = 1 THEN 0.00 ELSE CAST(e.endBal AS decimal(12,2)) END,
    CASE WHEN z.isZB = 1 AND lp.EventType = 'Prepaid' THEN CAST(e.endBal AS decimal(12,2)) ELSE 0.00 END,
    st.status,
    CASE st.status WHEN 'C' THEN 0 WHEN '30' THEN 30 WHEN '60' THEN 60
                   WHEN '90' THEN 90 WHEN '120' THEN 120 ELSE 150 END,
    CASE WHEN z.isZB = 1 AND lp.EventType = 'Prepaid' THEN '01'
         WHEN z.isZB = 1 AND lp.EventType = 'Default' THEN '09' END,
    CASE WHEN z.isZB = 1 THEN m.AsOfMonth END
FROM lp
CROSS APPLY GENERATE_SERIES(1, lp.EventAge) AS a
CROSS APPLY (SELECT AsOfMonth = DATEADD(MONTH, a.value - 1, lp.FirstPaymentDate)) AS m
CROSS APPLY (SELECT beginBal = lp.OriginalBalance * POWER(1 + lp.i, a.value - 1)
                              - lp.MonthlyPI * (POWER(1 + lp.i, a.value - 1) - 1) / lp.i) AS b
CROSS APPLY (SELECT schedInt  = b.beginBal * lp.i,
                    schedPrin = lp.MonthlyPI - b.beginBal * lp.i) AS c
CROSS APPLY (SELECT endBal = CASE WHEN b.beginBal - c.schedPrin < 0 THEN 0 ELSE b.beginBal - c.schedPrin END) AS e
CROSS APPLY (SELECT isZB = CASE WHEN a.value = lp.EventAge AND lp.EventType IN ('Prepaid','Default') THEN 1 ELSE 0 END,
                    mbe  = lp.EventAge - a.value) AS z
CROSS APPLY (SELECT status = CASE
                WHEN lp.EventType = 'Default' THEN
                     CASE z.mbe WHEN 0 THEN 'FC' WHEN 1 THEN 'FC' WHEN 2 THEN '120'
                                WHEN 3 THEN '90' WHEN 4 THEN '60' WHEN 5 THEN '30' ELSE 'C' END
                WHEN lp.BlipAge IS NOT NULL AND a.value BETWEEN lp.BlipAge AND lp.BlipAge + lp.BlipLen - 1 THEN
                     CASE a.value - lp.BlipAge WHEN 0 THEN '30' WHEN 1 THEN '60' ELSE '90' END
                ELSE 'C' END) AS st;
PRINT CONCAT('mtg.LoanPerformance : ', @@ROWCOUNT, ' monthly records');
GO

/* ---- CECL-lite PD assumptions (a model output in production) ---------------- */
CREATE TABLE mtg.PDAssumption (
    Segment varchar(3)   NOT NULL CONSTRAINT PK_mtg_PDAssumption PRIMARY KEY,   -- delinquency status
    PD      decimal(5,4) NOT NULL                                              -- 12-month prob. of default
);
INSERT mtg.PDAssumption (Segment, PD) VALUES
    ('C', 0.0040), ('30', 0.0500), ('60', 0.1500), ('90', 0.3500), ('120', 0.6000), ('FC', 0.8500);
GO

PRINT '';
SELECT EventType, Loans = COUNT(*),
       Pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,1))
FROM mtg.LoanFate GROUP BY EventType ORDER BY Loans DESC;

SELECT MinMonth = MIN(AsOfMonth), MaxMonth = MAX(AsOfMonth),
       Rows = COUNT(*), Loans = COUNT(DISTINCT LoanId)
FROM mtg.LoanPerformance;
GO

PRINT 'Portfolio generation complete.';
GO
