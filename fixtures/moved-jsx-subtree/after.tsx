export function Dashboard({ rows }) {
  return (
    <section>
      <Legend>
        Reported by DiffScope
        Warsaw office, third floor
      </Legend>
      <table className="results">
        <tbody>
          {rows.map((row) => (
            <tr key={row.id}>
              <td>{row.label}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
