CREATE OR REPLACE VIEW equipment_availability AS
SELECT
    e.id,
    e.productname AS name,
    e.totalqty AS quantity,
    e.totalqty - COALESCE(
        SUM(l.qty),
        0
    ) AS available_quantity
FROM equipment e
LEFT JOIN loans l
    ON e.id = l.equipment_id
    AND l.returned_at IS NULL
GROUP BY e.id, e.productname, e.totalqty;