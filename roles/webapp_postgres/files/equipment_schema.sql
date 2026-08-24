CREATE TABLE equipment (
    id serial PRIMARY KEY,
    name text NOT NULL,
    category text NOT NULL CHECK (category IN ('server', 'network', 'storage', 'spare_part', 'cable', 'other')),
    status text NOT NULL DEFAULT 'in_use' CHECK (status IN ('in_use', 'spare', 'maintenance', 'retired')),
    location text,
    serial_number text,
    quantity integer NOT NULL DEFAULT 1 CHECK (quantity >= 0),
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER equipment_updated_at
    BEFORE UPDATE ON equipment
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
