INSERT INTO equipment (ProductName, Category, TotalQty)
VALUES
('Camera Kit', 'Photography', 3),
('Tripod', 'Photography', 5),
('Wireless Mic', 'Audio', 4),
('Projector', 'Presentation', 2),
('HDMI Cable', 'Accessories', 10);

INSERT INTO loans (Equipment_ID, BorrowerName, Qty, Borrowed_At, Returned_At)
VALUES (1, 'Alice Smith', 1, '2026-11-22', NULL);
VALUES (99, 'Bob Jones', 2, '2026-11-22', NULL);