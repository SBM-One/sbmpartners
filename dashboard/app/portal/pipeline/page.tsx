import { redirect } from "next/navigation";

// The pipeline now lives on the portal's main page, under "The buyers".
export default async function PortalPipeline({ searchParams }: { searchParams: Promise<{ client?: string }> }) {
  const { client } = await searchParams;
  redirect(client ? `/portal?client=${encodeURIComponent(client)}#buyers` : "/portal#buyers");
}
