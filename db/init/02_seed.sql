-- Step 2: Seed sample data
-- Five equipment records and four loan records (two active, two returned)

INSERT INTO equipment (name, category, total_quantity)
VALUES
('Camera Kit', 'Photography', 3),
('Tripod', 'Photography', 5),
('Wireless Mic', 'Audio', 4),
('Projector', 'Presentation', 2),
('HDMI Cable', 'Accessories', 10);

INSERT INTO loans (equipment_id, borrower_name, quantity, borrowed_at, returned_at)
VALUES
(1, 'Alice Smith', 1, '2026-11-20', NULL),
(2, 'Bob Jones', 2, '2026-11-15', '2026-11-18'),
(3, 'Charlie Brown', 1, '2026-11-21', NULL),
(4, 'Diana Prince', 1, '2026-11-19', '2026-11-22');
