CREATE OR REPLACE VIEW equipment_availability AS
SELECT
    e.id,
    e.name,
    e.quantity,
    e.quantity - COALESCE(
        SUM(l.quantity),
        0
    ) AS available_quantity
FROM equipment e
LEFT JOIN loans l
    ON e.id = l.equipment_id
    AND l.status = 'ACTIVE'
GROUP BY e.id, e.name, e.quantity;