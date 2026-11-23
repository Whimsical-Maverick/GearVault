-- Step 1/3: Equipment availability view
-- Calculates remaining available quantity by subtracting active loans from total stock

CREATE OR REPLACE VIEW equipment_availability AS
SELECT
    e.id,
    e.name,
    e.category,
    e.total_quantity,
    e.total_quantity - COALESCE(SUM(l.quantity), 0) AS available_quantity
FROM equipment e
LEFT JOIN loans l
    ON e.id = l.equipment_id
    AND l.returned_at IS NULL
GROUP BY e.id, e.name, e.category, e.total_quantity;
