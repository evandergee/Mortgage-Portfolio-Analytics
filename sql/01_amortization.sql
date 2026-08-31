/* =============================================================================
   Amortization schedule -- recursive CTE
   -----------------------------------------------------------------------------
   Given a loan, walk the standard fixed-rate amortization month by month:

       interest_k  = balance_(k-1) * rate/12
       principal_k = payment - interest_k
       balance_k   = balance_(k-1) - principal_k

   A stored proc rather than a function so it can carry OPTION (MAXRECURSION 0)
   -- a 360-month loan blows past the default recursion limit of 100.

   Run:  .\q.ps1 -File sql\01_amortization.sql
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE mtg.uspAmortizationSchedule
    @LoanId int
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH loan AS (
        SELECT OriginalBalance, MonthlyPI, TermMonths, FirstPaymentDate,
               i = CAST(NoteRate AS float) / 12.0
        FROM mtg.Loan
        WHERE LoanId = @LoanId
    ),
    sched AS (
        SELECT
            PaymentNo        = 1,
            PaymentDate      = FirstPaymentDate,
            BeginningBalance  = CAST(OriginalBalance AS decimal(14,2)),
            Interest          = CAST(OriginalBalance * i AS decimal(14,2)),
            Principal         = CAST(MonthlyPI - OriginalBalance * i AS decimal(14,2)),
            EndingBalance     = CAST(OriginalBalance - (MonthlyPI - OriginalBalance * i) AS decimal(14,2)),
            MonthlyPI, i, TermMonths
        FROM loan

        UNION ALL

        SELECT
            PaymentNo + 1,
            DATEADD(MONTH, 1, PaymentDate),
            EndingBalance,
            CAST(EndingBalance * i AS decimal(14,2)),
            CAST(MonthlyPI - EndingBalance * i AS decimal(14,2)),
            CAST(EndingBalance - (MonthlyPI - EndingBalance * i) AS decimal(14,2)),
            MonthlyPI, i, TermMonths
        FROM sched
        WHERE PaymentNo < TermMonths
    )
    SELECT
        PaymentNo,
        PaymentDate,
        BeginningBalance,
        Interest,
        -- the final scheduled payment absorbs the penny-rounding residual
        Principal     = CASE WHEN PaymentNo = TermMonths THEN BeginningBalance ELSE Principal END,
        EndingBalance = CASE WHEN PaymentNo = TermMonths THEN 0
                             WHEN EndingBalance < 0     THEN 0
                             ELSE EndingBalance END
    FROM sched
    ORDER BY PaymentNo
    OPTION (MAXRECURSION 0);
END;
GO

PRINT 'mtg.uspAmortizationSchedule created.  Try:  EXEC mtg.uspAmortizationSchedule 1;';
GO
