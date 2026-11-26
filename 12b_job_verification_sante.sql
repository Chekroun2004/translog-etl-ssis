/* TransLog Maroc (societe FICTIVE) - Job SQL Server Agent de verification de sante.
   Chaque matin a 07h00 (apres le chargement de 02h00) : etl.usp_verifier_sante.
   S'il y a du ROUGE, la procedure echoue, le job aussi : l'echec est visible dans
   l'historique de l'Agent (et pourra declencher un e-mail via un operator Database Mail). */
USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'TransLog - Verification sante')
    EXEC msdb.dbo.sp_delete_job @job_name = N'TransLog - Verification sante';
GO

EXEC msdb.dbo.sp_add_job
     @job_name    = N'TransLog - Verification sante',
     @enabled     = 1,
     @description = N'Tableau de sante des flux TransLog ; echoue si un composant est au ROUGE.';

EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'TransLog - Verification sante',
     @step_name     = N'Verifier la sante',
     @subsystem     = N'TSQL',
     @database_name = N'translog_dw',
     @command       = N'EXEC etl.usp_verifier_sante;',
     @on_success_action = 1,   -- quitter en succes
     @on_fail_action    = 2;   -- quitter en echec

EXEC msdb.dbo.sp_add_jobschedule
     @job_name          = N'TransLog - Verification sante',
     @name              = N'Matin 07h00',
     @freq_type         = 4,       -- quotidien
     @freq_interval     = 1,
     @active_start_time = 70000;   -- 07:00:00

EXEC msdb.dbo.sp_add_jobserver
     @job_name    = N'TransLog - Verification sante',
     @server_name = N'(local)';
GO
