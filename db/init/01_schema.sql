-- Step 1: Design database schema
-- Create equipment and loans tables with proper constraints

CREATE TABLE equipment (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    total_quantity INTEGER NOT NULL CHECK (total_quantity >= 0)
);

CREATE TABLE loans (
    id SERIAL PRIMARY KEY,
    equipment_id INTEGER NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
    borrower_name TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    borrowed_at DATE NOT NULL,
    returned_at DATE,
    CONSTRAINT chk_loan_returned_at CHECK (returned_at IS NULL OR returned_at >= borrowed_at)
);
