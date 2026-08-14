export function Dashboard({ rows }) {
  return (
    <section>
      <table className="results">
        <tbody>
          {rows.map((row) => (
            <tr key={row.id}>
              <td>{row.label}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <Legend>
        Reported by DiffScope
        Warsaw office, third floor
      </Legend>
    </section>
  );
}
