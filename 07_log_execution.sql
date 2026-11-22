/* TransLog Maroc (societe FICTIVE) - Journal d'execution des packages SSIS.
   Une ligne par execution : package, statut, volumes, watermark, message d'erreur.
   Base de la supervision : on sait quand un flux a tourne, ce qu'il a charge et s'il a echoue. */
USE translog_dw;
GO

IF OBJECT_ID('etl.log_execution') IS NULL
CREATE TABLE etl.log_execution (
    log_id            INT IDENTITY(1,1) PRIMARY KEY,
    package           NVARCHAR(100)  NOT NULL,
    statut            VARCHAR(10)    NOT NULL,   -- SUCCES ou ECHEC
    lignes_chargees   INT            NULL,
    ancien_watermark  INT            NULL,
    nouveau_watermark INT            NULL,
    message           NVARCHAR(4000) NULL,
    date_log          DATETIME2(0)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_log_statut CHECK (statut IN ('SUCCES', 'ECHEC'))
);
GO

CREATE OR ALTER PROCEDURE etl.usp_log_execution
    @package           NVARCHAR(100),
    @statut            VARCHAR(10),
    @lignes_chargees   INT = NULL,
    @ancien_watermark  INT = NULL,
    @nouveau_watermark INT = NULL,
    @message           NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.log_execution
        (package, statut, lignes_chargees, ancien_watermark, nouveau_watermark, message)
    VALUES
        (@package, @statut, @lignes_chargees, @ancien_watermark, @nouveau_watermark, @message);
END;
GO

/* Controle : dernieres executions */
-- SELECT TOP (20) * FROM etl.log_execution ORDER BY log_id DESC;
