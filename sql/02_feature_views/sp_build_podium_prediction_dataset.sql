CREATE OR ALTER PROCEDURE sp_build_podium_prediction_dataset
AS
BEGIN
    SET NOCOUNT ON;

    ---------------------------------------------------
    -- 1. Create / refresh base driver-race table
    ---------------------------------------------------

    DROP TABLE IF EXISTS podium_base;

    SELECT
        r.raceId,
        r.year,
        r.round,
        r.name AS race_name,
        r.date AS race_date,

        res.resultId,
        res.driverId,
        res.constructorId,

        d.forename + ' ' + d.surname AS driver_name,
        c.name AS constructor_name,

        res.grid,
        q.position AS qualifying_position,

        res.positionOrder AS finish_position,
        res.points,
        res.laps,
        res.statusId,

        CASE
            WHEN res.positionOrder <= 3 THEN 1
            ELSE 0
        END AS podium_finish

    INTO podium_base
    FROM results res

    LEFT JOIN races r
        ON res.raceId = r.raceId

    LEFT JOIN drivers d
        ON res.driverId = d.driverId

    LEFT JOIN constructors c
        ON res.constructorId = c.constructorId

    LEFT JOIN qualifying q
        ON res.raceId = q.raceId
        AND res.driverId = q.driverId
        AND res.constructorId = q.constructorId;


    ---------------------------------------------------
    -- 2. Create supporting views
    ---------------------------------------------------

    EXEC('
    CREATE OR ALTER VIEW vw_driver_recent_form AS
    WITH driver_race AS (
        SELECT
            res.raceId,
            res.driverId,
            r.year,
            r.round,
            res.positionOrder AS finish_position,
            res.points,
            q.position AS qualifying_position,
            CASE 
                WHEN res.positionOrder <= 3 THEN 1 
                ELSE 0 
            END AS podium_flag,
            CASE
                WHEN s.status = ''Finished'' OR s.status LIKE ''+%Lap%'' OR s.status LIKE ''+%Laps%''
                THEN 0
                ELSE 1
            END AS dnf_flag
        FROM results res
        INNER JOIN races r
            ON res.raceId = r.raceId
        LEFT JOIN qualifying q
            ON res.raceId = q.raceId
            AND res.driverId = q.driverId
            AND res.constructorId = q.constructorId
        LEFT JOIN status s
            ON res.statusId = s.statusId
    )
    SELECT
        raceId,
        driverId,

        AVG(CAST(finish_position AS FLOAT)) OVER (
            PARTITION BY driverId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS avg_finish_last_5,

        SUM(podium_flag) OVER (
            PARTITION BY driverId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS podiums_last_5,

        AVG(CAST(qualifying_position AS FLOAT)) OVER (
            PARTITION BY driverId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS avg_qualifying_last_5,

        AVG(CAST(dnf_flag AS FLOAT)) OVER (
            PARTITION BY driverId
            ORDER BY year, round
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
        ) AS dnf_rate_last_10

    FROM driver_race;
    ');


    EXEC('
    CREATE OR ALTER VIEW vw_constructor_recent_form AS
    WITH constructor_race AS (
        SELECT
            res.raceId,
            res.constructorId,
            r.year,
            r.round,
            AVG(CAST(res.positionOrder AS FLOAT)) AS constructor_avg_finish,
            SUM(CAST(res.points AS FLOAT)) AS constructor_points,
            SUM(CASE WHEN res.positionOrder <= 3 THEN 1 ELSE 0 END) AS constructor_podiums
        FROM results res
        INNER JOIN races r
            ON res.raceId = r.raceId
        GROUP BY
            res.raceId,
            res.constructorId,
            r.year,
            r.round
    )
    SELECT
        raceId,
        constructorId,

        AVG(constructor_avg_finish) OVER (
            PARTITION BY constructorId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS constructor_avg_finish_last_5,

        SUM(constructor_points) OVER (
            PARTITION BY constructorId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS constructor_points_last_5,

        AVG(CAST(constructor_podiums AS FLOAT)) OVER (
            PARTITION BY constructorId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS constructor_podium_rate_last_5

    FROM constructor_race;
    ');


    EXEC('
    CREATE OR ALTER VIEW vw_qualifying_features AS
    WITH quali_clean AS (
        SELECT
            q.raceId,
            q.driverId,
            q.constructorId,
            q.position AS qualifying_position,

            CASE 
                WHEN q.q3 IS NOT NULL AND q.q3 <> ''\N'' THEN q.q3
                WHEN q.q2 IS NOT NULL AND q.q2 <> ''\N'' THEN q.q2
                WHEN q.q1 IS NOT NULL AND q.q1 <> ''\N'' THEN q.q1
                ELSE NULL
            END AS best_quali_time
        FROM qualifying q
    ),
    quali_ms AS (
        SELECT
            raceId,
            driverId,
            constructorId,
            qualifying_position,
            best_quali_time,

            CASE
                WHEN best_quali_time IS NULL THEN NULL
                ELSE
                    TRY_CAST(LEFT(best_quali_time, CHARINDEX('':'', best_quali_time) - 1) AS FLOAT) * 60000
                    +
                    TRY_CAST(SUBSTRING(
                        best_quali_time,
                        CHARINDEX('':'', best_quali_time) + 1,
                        LEN(best_quali_time)
                    ) AS FLOAT) * 1000
            END AS best_quali_ms
        FROM quali_clean
        WHERE best_quali_time IS NULL OR CHARINDEX('':'', best_quali_time) > 0
    ),
    quali_features AS (
        SELECT
            raceId,
            driverId,
            constructorId,
            qualifying_position,
            best_quali_ms,

            MIN(best_quali_ms) OVER (
                PARTITION BY raceId
            ) AS pole_time_ms,

            AVG(best_quali_ms) OVER (
                PARTITION BY raceId, constructorId
            ) AS constructor_avg_quali_ms
        FROM quali_ms
    )
    SELECT
        raceId,
        driverId,
        constructorId,
        qualifying_position,
        best_quali_ms,
        best_quali_ms - pole_time_ms AS qualifying_gap_to_pole_ms,
        best_quali_ms - constructor_avg_quali_ms AS teammate_qualifying_gap_ms
    FROM quali_features;
    ');


    EXEC('
    CREATE OR ALTER VIEW vw_pit_stop_features AS
    WITH constructor_pit_race AS (
        SELECT
            ps.raceId,
            res.constructorId,
            r.year,
            r.round,

            AVG(TRY_CAST(NULLIF(ps.milliseconds, ''\N'') AS FLOAT)) AS constructor_avg_pit_ms,

            STDEV(TRY_CAST(NULLIF(ps.milliseconds, ''\N'') AS FLOAT)) AS constructor_pit_consistency_ms,

            COUNT(*) AS total_pit_stops

        FROM pit_stops ps
        INNER JOIN results res
            ON ps.raceId = res.raceId
            AND ps.driverId = res.driverId
        INNER JOIN races r
            ON ps.raceId = r.raceId
        GROUP BY
            ps.raceId,
            res.constructorId,
            r.year,
            r.round
    )
    SELECT
        raceId,
        constructorId,

        AVG(constructor_avg_pit_ms) OVER (
            PARTITION BY constructorId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS avg_pit_ms_last_5,

        AVG(constructor_pit_consistency_ms) OVER (
            PARTITION BY constructorId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS pit_consistency_last_5,

        SUM(total_pit_stops) OVER (
            PARTITION BY constructorId
            ORDER BY year, round
            ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
        ) AS total_pit_stops_last_5

    FROM constructor_pit_race;
    ');


    EXEC('
    CREATE OR ALTER VIEW vw_reliability_features AS
    WITH reliability_base AS (
        SELECT
            res.raceId,
            res.driverId,
            res.constructorId,
            r.year,
            r.round,
            CASE
                WHEN s.status = ''Finished'' OR s.status LIKE ''+%Lap%'' OR s.status LIKE ''+%Laps%''
                THEN 0
                ELSE 1
            END AS dnf_flag
        FROM results res
        INNER JOIN races r
            ON res.raceId = r.raceId
        LEFT JOIN status s
            ON res.statusId = s.statusId
    ),
    driver_reliability AS (
        SELECT
            raceId,
            driverId,

            AVG(CAST(dnf_flag AS FLOAT)) OVER (
                PARTITION BY driverId
                ORDER BY year, round
                ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
            ) AS driver_dnf_rate_last_10
        FROM reliability_base
    ),
    constructor_reliability AS (
        SELECT
            raceId,
            constructorId,

            AVG(CAST(dnf_flag AS FLOAT)) OVER (
                PARTITION BY constructorId
                ORDER BY year, round
                ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING
            ) AS constructor_dnf_rate_last_20
        FROM reliability_base
    )
    SELECT
        rb.raceId,
        rb.driverId,
        rb.constructorId,
        dr.driver_dnf_rate_last_10,
        cr.constructor_dnf_rate_last_20
    FROM reliability_base rb
    LEFT JOIN driver_reliability dr
        ON rb.raceId = dr.raceId
        AND rb.driverId = dr.driverId
    LEFT JOIN constructor_reliability cr
        ON rb.raceId = cr.raceId
        AND rb.constructorId = cr.constructorId;
    ');


    ---------------------------------------------------
    -- 3. Create final view
    ---------------------------------------------------

    EXEC('
    CREATE OR ALTER VIEW vw_podium_prediction_dataset AS
    SELECT
        pb.raceId,
        pb.year,
        pb.round,
        pb.race_name,
        pb.race_date,
        pb.resultId,
        pb.driverId,
        pb.constructorId,
        pb.driver_name,
        pb.constructor_name,

        pb.grid,
        qf.qualifying_position,
        qf.best_quali_ms,
        qf.qualifying_gap_to_pole_ms,
        qf.teammate_qualifying_gap_ms,

        drf.avg_finish_last_5,
        drf.podiums_last_5,
        drf.avg_qualifying_last_5,
        drf.dnf_rate_last_10,

        crf.constructor_avg_finish_last_5,
        crf.constructor_points_last_5,
        crf.constructor_podium_rate_last_5,

        psf.avg_pit_ms_last_5,
        psf.pit_consistency_last_5,
        psf.total_pit_stops_last_5,

        rf.driver_dnf_rate_last_10,
        rf.constructor_dnf_rate_last_20,

        pb.finish_position,
        pb.points,
        pb.podium_finish

    FROM podium_base pb

    LEFT JOIN vw_qualifying_features qf
        ON pb.raceId = qf.raceId
        AND pb.driverId = qf.driverId
        AND pb.constructorId = qf.constructorId

    LEFT JOIN vw_driver_recent_form drf
        ON pb.raceId = drf.raceId
        AND pb.driverId = drf.driverId

    LEFT JOIN vw_constructor_recent_form crf
        ON pb.raceId = crf.raceId
        AND pb.constructorId = crf.constructorId

    LEFT JOIN vw_pit_stop_features psf
        ON pb.raceId = psf.raceId
        AND pb.constructorId = psf.constructorId

    LEFT JOIN vw_reliability_features rf
        ON pb.raceId = rf.raceId
        AND pb.driverId = rf.driverId
        AND pb.constructorId = rf.constructorId;
    ');


    ---------------------------------------------------
    -- 4. Create / refresh final ML table
    ---------------------------------------------------

    DROP TABLE IF EXISTS podium_prediction_dataset;

    SELECT *
    INTO podium_prediction_dataset
    FROM vw_podium_prediction_dataset;


    ---------------------------------------------------
    -- 5. Quick summary
    ---------------------------------------------------

    SELECT
        COUNT(*) AS total_rows,
        SUM(CASE WHEN podium_finish = 1 THEN 1 ELSE 0 END) AS podium_rows,
        SUM(CASE WHEN podium_finish = 0 THEN 1 ELSE 0 END) AS non_podium_rows
    FROM podium_prediction_dataset;

END;